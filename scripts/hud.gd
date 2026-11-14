## HUD and modals, built in code. Owns the async flows that wake the LLM node:
## Phase 1 negotiation and Phase 4 emergency awakening.
extends CanvasLayer

const D = preload("res://scripts/data.gd")
const Persona = preload("res://scripts/persona_engine.gd")

const WV = preload("res://scripts/world_view.gd")
var sim
var world
var llm

var top_stats: RichTextLabel
var pause_btn: Button
var speed_btns: Array = []
var left_title: Label
var roster_box: VBoxContainer
var roster_buttons := {}
var sheet_box: VBoxContainer
var sheet_text: RichTextLabel
var sheet_contract_btn: Button
var sheet_steward_btn: Button
var sheet_chief_btn: Button
var contracts_text: RichTextLabel
var log_text: RichTextLabel
var policy_opt: OptionButton
var build_btns := {}
var modal: Control = null
var modal_token := 0
var refresh_t := 0.0
var log_dirty := true
var roster_sig := ""
var roster_headers := {} # group key -> Button
var sheet_scout_btn: Button
var sheet_research_btn: Button
var reno_btn: Button
var minimap: Control
const MINI_W := 314.0

const COL_BG := Color(0.11, 0.09, 0.07, 0.92)
const COL_EDGE := Color(0.55, 0.42, 0.25)
const COL_TEXT := Color("#f1e4c8")
const COL_DIM := Color("#b8a888")
const COL_ACCENT := Color("#ffd36b")

func setup(s, w, l) -> void:
	sim = s
	world = w
	llm = l
	layer = 10
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _make_theme()
	add_child(root)
	_build_top(root)
	_build_left(root)
	_build_right(root)
	sim.log_added.connect(func(): log_dirty = true)
	sim.contract_interrupted.connect(_on_interrupt)
	sim.event_fired.connect(_on_event)
	sim.contract_finished.connect(func(c): _toast_contract_done(c))
	world.selection_changed.connect(_refresh_left)
	_refresh_left()
	_show_intro()

func modal_open() -> bool:
	return modal != null

# ------------------------------------------------------------ theme & helpers
func _make_theme() -> Theme:
	var th := Theme.new()
	var panel := StyleBoxFlat.new()
	panel.bg_color = COL_BG
	panel.border_color = COL_EDGE
	panel.set_border_width_all(2)
	panel.set_corner_radius_all(6)
	panel.set_content_margin_all(10)
	th.set_stylebox("panel", "PanelContainer", panel)
	var btn := StyleBoxFlat.new()
	btn.bg_color = Color(0.28, 0.2, 0.12)
	btn.border_color = Color(0.6, 0.45, 0.25)
	btn.set_border_width_all(1)
	btn.set_corner_radius_all(4)
	btn.content_margin_left = 10
	btn.content_margin_right = 10
	btn.content_margin_top = 5
	btn.content_margin_bottom = 5
	var hov := btn.duplicate()
	hov.bg_color = Color(0.4, 0.29, 0.16)
	var prs := btn.duplicate()
	prs.bg_color = Color(0.55, 0.38, 0.18)
	var dis := btn.duplicate()
	dis.bg_color = Color(0.18, 0.15, 0.12)
	dis.border_color = Color(0.3, 0.25, 0.2)
	th.set_stylebox("normal", "Button", btn)
	th.set_stylebox("hover", "Button", hov)
	th.set_stylebox("pressed", "Button", prs)
	th.set_stylebox("disabled", "Button", dis)
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_color("font_color", "Button", COL_TEXT)
	th.set_color("font_disabled_color", "Button", Color(0.5, 0.45, 0.4))
	th.set_color("font_color", "Label", COL_TEXT)
	th.set_color("default_color", "RichTextLabel", COL_TEXT)
	th.set_font_size("font_size", "Button", 15)
	th.set_font_size("font_size", "Label", 15)
	th.set_font_size("normal_font_size", "RichTextLabel", 15)
	th.set_font_size("bold_font_size", "RichTextLabel", 15)
	th.set_font_size("italics_font_size", "RichTextLabel", 15)
	th.set_font_size("font_size", "LineEdit", 15)
	var le := StyleBoxFlat.new()
	le.bg_color = Color(0.06, 0.05, 0.04)
	le.border_color = Color(0.45, 0.35, 0.22)
	le.set_border_width_all(1)
	le.set_corner_radius_all(3)
	le.set_content_margin_all(6)
	th.set_stylebox("normal", "LineEdit", le)
	th.set_color("font_color", "LineEdit", COL_TEXT)
	return th

func _label(text: String, size := 15, col := COL_TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	# Wrapping labels collapse to 1 char wide inside H/Grid containers; only wrap long prose.
	if text.length() > 60:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(200, 0)
	return l

func _rich(min_h := 0.0, fit := false) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = fit
	r.scroll_active = not fit
	r.custom_minimum_size = Vector2(0, min_h)
	r.selection_enabled = false
	return r

func _button(text: String, cb: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(cb)
	return b

func _header(text: String) -> Label:
	return _label(text, 14, COL_ACCENT)

# ------------------------------------------------------------ layout
func _build_top(root: Control) -> void:
	var p := PanelContainer.new()
	p.anchor_right = 1.0
	p.offset_bottom = 50
	root.add_child(p)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	p.add_child(h)
	var title := _label("ERA OF SAVAGERY · Clan Chronicles", 18, COL_ACCENT)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	h.add_child(title)
	top_stats = _rich(0, false)
	top_stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_stats.custom_minimum_size = Vector2(0, 28)
	top_stats.scroll_active = false
	h.add_child(top_stats)
	pause_btn = _button("Pause", func(): sim.paused = not sim.paused, "Space")
	h.add_child(pause_btn)
	for sp in [1, 2, 4]:
		var b := _button("%dx" % sp, func(): sim.speed = sp)
		speed_btns.append(b)
		h.add_child(b)
	h.add_child(_button("Wisdom & Culture", _open_tech, "T: what the tribe knows, how it is learning, and who it is becoming"))
	h.add_child(_button("LLM Settings", _open_settings))
	h.add_child(_button("?", _show_intro))

func _build_left(root: Control) -> void:
	var p := PanelContainer.new()
	p.anchor_bottom = 1.0
	p.offset_top = 56
	p.offset_right = 340
	p.offset_bottom = -6 - (MINI_W / 2 + 20) - 6
	p.offset_left = 6
	root.add_child(p)
	_build_minimap(root)
	var v := VBoxContainer.new()
	p.add_child(v)
	left_title = _header("TRIBE")
	v.add_child(left_title)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(inner)
	roster_box = VBoxContainer.new()
	roster_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(roster_box)
	sheet_box = VBoxContainer.new()
	sheet_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(sheet_box)
	sheet_text = _rich(0, true)
	sheet_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sheet_box.add_child(sheet_text)
	sheet_contract_btn = _button("Assign Task Contract…", func(): _start_contract_for_selected(), "Tier 2: negotiate a semi-autonomous goal with this leader")
	sheet_box.add_child(sheet_contract_btn)
	sheet_scout_btn = _button("Scout the unknown (X)", func(): world.scout_selected(), "Auto-explore: walk to the nearest unexplored land until called back (right-click)")
	sheet_box.add_child(sheet_scout_btn)
	sheet_research_btn = _button("Seek new wisdom…", func():
		var sel: Array = world.selected_units()
		if sel.size() == 1: open_negotiation(sel[0], "research"), "Tier 2: a research Task Contract - the leader proposes which idea to pursue and how")
	sheet_box.add_child(sheet_research_btn)
	var hb := HBoxContainer.new()
	sheet_box.add_child(hb)
	sheet_steward_btn = _button("Appoint Steward", func(): _appoint("steward"), "Tier 3: auto-manages idle villagers")
	sheet_chief_btn = _button("Appoint War Chief", func(): _appoint("warchief"), "Tier 3: rallies warriors vs. beasts near the village (needs Tribal Code)")
	sheet_steward_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sheet_chief_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(sheet_steward_btn)
	hb.add_child(sheet_chief_btn)
	sheet_box.add_child(_button("← Back to tribe roster", func(): world.select_only(null)))

# ------------------------------------------------------------ minimap
func _build_minimap(root: Control) -> void:
	var p := PanelContainer.new()
	p.anchor_top = 1.0
	p.anchor_bottom = 1.0
	p.offset_left = 6
	p.offset_right = 340
	p.offset_top = -6 - (MINI_W / 2 + 20)
	p.offset_bottom = -6
	root.add_child(p)
	minimap = Control.new()
	minimap.custom_minimum_size = Vector2(MINI_W, MINI_W / 2)
	minimap.mouse_filter = Control.MOUSE_FILTER_STOP
	minimap.clip_contents = true
	minimap.tooltip_text = "Minimap: left-click to look, right-click to send the selected people"
	p.add_child(minimap)
	minimap.draw.connect(_draw_minimap)
	minimap.gui_input.connect(_minimap_input)

func _mm_scale() -> float:
	return minimap.size.x / ((D.W + D.H) * WV.IX)

## Iso canvas point -> minimap point.
func _mm_pt(sp: Vector2) -> Vector2:
	return (sp + Vector2(D.H * WV.IX, 0)) * _mm_scale()

func _draw_minimap() -> void:
	var k := _mm_scale()
	var mm := minimap
	mm.draw_rect(Rect2(Vector2.ZERO, mm.size), Color("#141210"))
	var xf := Transform2D(0.0, Vector2(k, k), 0.0, Vector2(D.H * WV.IX * k, 0)) * WV.GROUND
	mm.draw_set_transform_matrix(xf)
	mm.draw_texture_rect(world.terrain_tex, Rect2(0, 0, D.W, D.H), false)
	if sim.fog_enabled: mm.draw_texture_rect(world.fog_tex, Rect2(0, 0, sim.fog_w * D.FOG_CELL, sim.fog_h * D.FOG_CELL), false)
	mm.draw_set_transform_matrix(Transform2D.IDENTITY)
	for st in sim.structures:
		if sim.is_explored(st.pos): mm.draw_rect(Rect2(_mm_pt(WV.iso(st.pos)) - Vector2(2, 2), Vector2(4, 4)), Color("#c9a24f"))
	for lm in sim.landmarks:
		if lm["found"]:
			var q := _mm_pt(WV.iso(lm["pos"]))
			mm.draw_colored_polygon(PackedVector2Array([q + Vector2(0, -4), q + Vector2(4, 0), q + Vector2(0, 4), q + Vector2(-4, 0)]), Color("#ff6b5a") if lm["kind"] == "den" else Color("#ffe066"))
	for pr in sim.predators:
		if not pr.dead and not pr.fled and sim.is_visible(pr.pos): mm.draw_circle(_mm_pt(WV.iso(pr.pos)), 2.5, Color("#ff4a3a"))
	for u in sim.units:
		if u.dead: continue
		var sel: bool = u.id in world.selected
		mm.draw_circle(_mm_pt(WV.iso(u.pos)), 3.0 if sel else 2.2, Color("#ffffff") if sel else u.color.lightened(0.3))
	var vs: Vector2 = world.get_viewport_rect().size / world.cam.zoom.x
	var r := Rect2(_mm_pt(world.cam.get_screen_center_position() - vs / 2), vs * k)
	mm.draw_rect(r, Color(1, 1, 1, 0.85), false, 1.0)

func _minimap_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	var mm := ev as InputEventMouseMotion
	var pos := Vector2.ZERO
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT: pos = mb.position
	elif mm and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT): pos = mm.position
	elif mb and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
		world.command_at(WV.uniso(mb.position / _mm_scale() - Vector2(D.H * WV.IX, 0)))
		minimap.accept_event()
		return
	else: return
	world.cam.position = pos / _mm_scale() - Vector2(D.H * WV.IX, 0)
	world._clamp_cam()
	minimap.accept_event()

func _build_right(root: Control) -> void:
	var p := PanelContainer.new()
	p.anchor_left = 1.0
	p.anchor_right = 1.0
	p.anchor_bottom = 1.0
	p.offset_left = -350
	p.offset_right = -6
	p.offset_top = 56
	p.offset_bottom = -6
	root.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	v.add_child(_header("BUILD (select workers, then place)"))
	var grid := GridContainer.new()
	grid.columns = 2
	v.add_child(grid)
	for k in D.VILLAGE_BUILDS:
		var sd: Dictionary = D.STRUCTURES[k]
		var b := _button("%s (%s)" % [sd["name"], _cost_short(sd)], func(): world.build_type = k, "Costs " + _cost_long(sd))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.clip_text = true
		b.custom_minimum_size = Vector2(60, 0)
		build_btns[k] = b
		grid.add_child(b)
	reno_btn = _button("", func():
		var free: Array = world.selected_units().filter(func(u): return u.role != "contract")
		var err: String = sim.renovate(free)
		if err != "": sim.popup(D.VILLAGE, err, Color("#ff8080")), "Rebuild old homes and walls in the current era's style")
	reno_btn.visible = false
	reno_btn.clip_text = true
	v.add_child(reno_btn)
	var ph := HBoxContainer.new()
	v.add_child(ph)
	var pl := _label("Steward policy:", 14, COL_DIM)
	pl.autowrap_mode = TextServer.AUTOWRAP_OFF
	ph.add_child(pl)
	policy_opt = OptionButton.new()
	for pol in ["balanced", "food", "wood", "stone", "lore"]: policy_opt.add_item(pol)
	policy_opt.item_selected.connect(func(i): sim.steward_policy = policy_opt.get_item_text(i))
	policy_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ph.add_child(policy_opt)
	v.add_child(_header("TASK CONTRACTS"))
	contracts_text = _rich(170)
	v.add_child(contracts_text)
	v.add_child(_header("CHRONICLE"))
	log_text = _rich(0)
	log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(log_text)
	v.add_child(_label("LMB select/drag · RMB command (tree/bush/deer = gather, tiger = attack, site = build) · pan: WASD / screen edge / MMB drag / two-finger swipe · zoom: wheel / pinch · Space pause · F11 fullscreen", 12, COL_DIM))

# ------------------------------------------------------------ periodic refresh
func _process(delta: float) -> void:
	if minimap: minimap.queue_redraw()
	refresh_t -= delta
	if refresh_t > 0: return
	refresh_t = 0.25
	_refresh_top()
	_refresh_left_content()
	_refresh_right()

func _refresh_top() -> void:
	var f: float = sim.day_frac()
	var phase := "Night" if sim.night_amt > 0.5 else ("Dusk" if f > 0.65 else "Day")
	var since: String = "%.0fs" % (sim.ticks_since_llm * 0.05) if sim.llm_calls > 0 else "-"
	top_stats.text = "[color=#ffd36b]Day %d[/color] %s · [color=#e6c890]%s[/color]   [color=#f0a07a]Food %d[/color]   [color=#d8b483]Wood %d[/color]   [color=#c8c8d0]Stone %d[/color]   [color=#c8a8ff]Lore %d[/color]   Pop %d/%d   [color=#ffb0e0]Devotion %d%%[/color]   [color=#b6f28a]Explored %d%%[/color]   [color=#9fd0ff]LLM calls: %d[/color] [color=#8a9aa8](%s)[/color]" % [
		sim.day(), phase, D.ERA_NAMES[sim.evo.era], sim.stock["food"], sim.stock["wood"], sim.stock["stone"], sim.stock["lore"], sim.living().size(), sim.pop_cap(),
		sim.devotion, sim.explored_pct(), sim.llm_calls, "offline" if not llm.is_online() else llm.model]
	pause_btn.text = "Resume" if sim.paused else "Pause"
	for i in speed_btns.size():
		speed_btns[i].modulate = COL_ACCENT if sim.speed == [1, 2, 4][i] else Color.WHITE

func _refresh_left() -> void:
	var sel: Array = world.selected_units()
	var single: bool = sel.size() == 1
	roster_box.visible = not single
	sheet_box.visible = single
	if not single:
		for c in roster_box.get_children(): c.queue_free()
		roster_buttons.clear()
		roster_headers.clear()
		roster_sig = _roster_signature()
		for g in _roster_groups():
			var members: Array = g["units"]
			var hb := _button("", func():
				world.selected = members.map(func(u): return u.id)
				world.selection_changed.emit()
				world.focus_on(g["focus"]))
			hb.alignment = HORIZONTAL_ALIGNMENT_LEFT
			hb.clip_text = true
			hb.flat = true
			hb.add_theme_color_override("font_color", g["color"])
			hb.tooltip_text = "Select this whole group"
			roster_box.add_child(hb)
			roster_headers[g["key"]] = hb
			for u in members:
				var b := _button("", func(): world.select_only(u); world.focus_on(u.pos))
				b.alignment = HORIZONTAL_ALIGNMENT_LEFT
				b.clip_text = true
				roster_box.add_child(b)
				roster_buttons[u.id] = b
	_refresh_left_content()

## People grouped by what they are doing: one group per running Task Contract (its crew,
## leader first), then scouts out exploring, then everyone in the village.
func _roster_groups() -> Array:
	var groups: Array = []
	var placed := {}
	for c in sim.contracts.list:
		if not sim.contracts.is_running(c): continue
		var crew: Array = sim.living().filter(func(u): return u.role == "contract" and u.contract_id == c.id)
		if crew.is_empty(): continue
		crew.sort_custom(func(a, b): return a.id == c.leader_id and b.id != c.leader_id)
		for u in crew: placed[u.id] = true
		groups.append({"key": "c%d" % c.id, "contract": c, "units": crew, "focus": c.site, "color": Color("#ff8a7a") if c.status in ["interrupted", "defending"] else Color("#9fd0ff")})
	var scouts: Array = sim.living().filter(func(u): return not placed.has(u.id) and u.job.get("type", "") == "explore")
	for u in scouts: placed[u.id] = true
	if not scouts.is_empty():
		groups.append({"key": "scouts", "units": scouts, "focus": scouts[0].pos, "color": Color("#b6f28a")})
	var rest: Array = sim.living().filter(func(u): return not placed.has(u.id))
	if not rest.is_empty():
		groups.append({"key": "village", "units": rest, "focus": D.VILLAGE, "color": COL_ACCENT})
	return groups

func _roster_signature() -> String:
	var parts: Array = []
	for u in sim.living():
		parts.append("%d:%d:%s" % [u.id, u.contract_id if u.role == "contract" else -1, "x" if u.job.get("type", "") == "explore" else ""])
	for c in sim.contracts.list: parts.append("c%d%s" % [c.id, c.status])
	return ",".join(parts)

func _group_title(key: String, units: Array) -> String:
	if key == "scouts": return "▸ SCOUTING THE UNKNOWN (%d)" % units.size()
	if key == "village": return "▸ VILLAGE (%d)" % units.size()
	var c = sim.contracts.by_id(int(key.substr(1)))
	if c == null: return key
	var ld = sim.unit_by_id(c.leader_id)
	return "⚑ %s · %s %d%% (%d)" % [c.plan["plan_id"], c.status, roundi(c.progress * 100), units.size()]

func _refresh_left_content() -> void:
	var sel: Array = world.selected_units()
	if sel.size() != 1:
		left_title.text = "TRIBE (%d)%s" % [sim.living().size(), "  · %d selected" % sel.size() if sel.size() > 1 else ""]
		if _roster_signature() != roster_sig:
			_refresh_left()
			return
		for g in _roster_groups():
			if roster_headers.has(g["key"]): roster_headers[g["key"]].text = _group_title(g["key"], g["units"])
		for id in roster_buttons:
			var u = sim.unit_by_id(id)
			var tag: String = " ★" + u.title if u.title != "" else ""
			var c = sim.contracts.by_id(u.contract_id) if u.role == "contract" else null
			if c and c.leader_id == u.id: tag += " [leader]"
			roster_buttons[id].text = "   %s Lv%d%s — %s" % [u.name, sim.unit_level(u), tag, u.act]
			roster_buttons[id].modulate = COL_ACCENT if u.id in world.selected else Color.WHITE
		return
	var u = sel[0]
	left_title.text = "CHARACTER SHEET"
	var tr: Array = []
	for t in u.traits: tr.append(D.TRAITS[t]["name"])
	var s := "[font_size=20][color=#ffd36b]%s[/color][/font_size]  [color=#b8a888]%s[/color]\n" % [u.name, u.epithet]
	if u.title != "": s += "[color=#9fd0ff]★ Vice-Chieftain: %s[/color]\n" % u.title
	if u.hero: s += "[color=#ffd36b]Mythic bloodline[/color]\n"
	s += "[color=#e6b8ff]%s[/color] · Level %d\n" % [", ".join(tr), sim.unit_level(u)]
	s += "HP %d/%d   Hunger %d%%\nATK %.1f   DEF %.1f   SPD %.2f   Kills %d\n" % [u.hp, u.max_hp, u.hunger, sim.unit_atk(u), sim.unit_def(u), u.spd, u.kills]
	s += "[color=#b8a888]Now:[/color] %s\n" % u.act
	var knows: Array = sim.evo.known_by(u).map(func(id): return sim.evo.tech_def(id)["name"])
	s += "[color=#b8a888]Knows:[/color] %s\n\n" % (", ".join(knows) if not knows.is_empty() else "[color=#8a7a60]only the old ways[/color]")
	s += "[color=#ffd36b]SPECIALIZATIONS[/color]\n"
	for k in D.SKILLS:
		var sk: Dictionary = u.skills[k]
		var need: float = sim.xp_need(sk["lv"])
		var bars := int(10.0 * sk["xp"] / need) if sk["lv"] < 10 else 10
		var unlock: String = (" [color=#7ff0ff][%s][/color]" % D.SKILL_UNLOCKS[k]) if sk["lv"] >= 5 else ""
		s += "%s  Lv.%d%s\n[bgcolor=#6fb04f]%s[/bgcolor][bgcolor=#3a3226]%s[/bgcolor] [color=#8a7a60]%d/%d xp[/color]\n" % [D.SKILL_NAMES[k], sk["lv"], unlock, " ".repeat(bars * 3), " ".repeat((10 - bars) * 3), sk["xp"], need]
	s += "\n[color=#ffd36b]MEMORY ARCHIVE[/color] [color=#8a7a60](10 most impactful)[/color]\n"
	var mem: Array = u.memory.duplicate()
	mem.sort_custom(func(a, b): return a["day"] > b["day"])
	for m in mem:
		var when: String = ("Day %d" % m["day"]) if m["day"] > 0 else "Long ago"
		s += "[color=#8a7a60]%s ·%s[/color] %s\n" % [when, "◆".repeat(clampi(int(m["impact"] / 3), 1, 3)), _cap(m["text"])]
	sheet_text.text = s
	var on_contract: bool = u.role == "contract"
	sheet_contract_btn.disabled = on_contract or D.bank_of(u.pos) != "west"
	sheet_contract_btn.text = "On contract — executing blueprint" if on_contract else "Assign Task Contract…"
	sheet_scout_btn.disabled = on_contract
	sheet_research_btn.disabled = on_contract or sim.evo.candidates().is_empty() or D.bank_of(u.pos) != "west"
	sheet_research_btn.text = "Seek new wisdom…" if not sim.evo.candidates().is_empty() else "No new wisdom within reach"
	sheet_scout_btn.text = "Scouting… (right-click to recall)" if u.job.get("type", "") == "explore" else "Scout the unknown (X)"
	sheet_steward_btn.disabled = sim.vice["steward"] == u.id
	sheet_chief_btn.disabled = sim.vice["warchief"] == u.id or sim.vice_slots() < 2

func _cap(s: String) -> String:
	return s.substr(0, 1).to_upper() + s.substr(1) if s.length() > 0 else s

func _refresh_right() -> void:
	for k in build_btns:
		var sd: Dictionary = D.STRUCTURES[k]
		var locked: bool = sd.has("tech") and not sim.has_tech(sd["tech"])
		build_btns[k].disabled = locked or sim.stock["wood"] < sd["wood"] or sim.stock["stone"] < sd.get("stone", 0)
		build_btns[k].tooltip_text = ("Requires %s" % sim.evo.tech_def(sd["tech"])["name"]) if locked else ("Costs " + _cost_long(sd))
	var old: Array = sim.outdated()
	reno_btn.visible = not old.is_empty()
	if not old.is_empty():
		var rc: Dictionary = sim.reno_cost(old)
		reno_btn.text = "Renovate %d homes in %s style (%dw%s)" % [old.size(), ["", "hide", "mud & thatch", "timber & stone"][sim.evo.era], rc["wood"], (" %ds" % rc["stone"]) if rc["stone"] > 0 else ""]
		reno_btn.disabled = sim.stock["wood"] < rc["wood"] or sim.stock["stone"] < rc["stone"]
	var s := ""
	if sim.contracts.list.is_empty():
		s = "[color=#8a7a60]None yet. Select a tribesperson and press 'Assign Task Contract'.[/color]"
	for c in sim.contracts.list:
		var ld = sim.unit_by_id(c.leader_id)
		var col: String = {"done": "#b6f28a", "abandoned": "#999999", "failed": "#999999", "interrupted": "#ff6b6b", "defending": "#ff6b6b"}.get(c.status, "#ffd36b")
		s += "[color=%s]■[/color] [b]%s[/b] — %s\n  %s · [color=%s]%s %d%%[/color] · step %d/%d\n" % [col, c.plan["plan_id"], ld.name if ld else "?", c.substate if c.status == "executing" else "", col, c.status, roundi(c.progress * 100), mini(c.step_idx + 1, c.steps.size()), c.steps.size()]
		s += "  [color=#8a9aa8]LLM calls: 1 negotiation + %d awakenings[/color]\n" % c.interruptions
		for line in c.events.slice(0, 3): s += "  [color=#a89878]%s[/color]\n" % line
	contracts_text.text = s
	if log_dirty:
		log_dirty = false
		var l := ""
		var colors := {"danger": "#ff8a8a", "story": "#ffd6a0", "contract": "#9fd0ff", "tech": "#c8a8ff", "vice": "#a8e0a8", "combat": "#ffb07a", "xp": "#7ff0ff", "build": "#b6f28a"}
		for e in sim.log_lines.slice(0, 40):
			l += "[color=#7a6a50]D%d[/color] [color=%s]%s[/color]\n" % [e["day"], colors.get(e["kind"], "#d8ccb0"), e["text"]]
		log_text.text = l

func _cost_short(sd: Dictionary) -> String:
	return "%d" % sd["wood"] if sd.get("stone", 0) == 0 else "%dw %ds" % [sd["wood"], sd["stone"]]

func _cost_long(sd: Dictionary) -> String:
	return "%d wood" % sd["wood"] + ((" and %d stone" % sd["stone"]) if sd.get("stone", 0) > 0 else "")

func _appoint(role: String) -> void:
	var sel: Array = world.selected_units()
	if sel.size() != 1: return
	if not sim.appoint(sel[0], role):
		sim.popup(sel[0].pos, "No Vice-Chieftain slot free (Tribal Code adds one)", Color("#ff8080"))
	_refresh_left_content()

# ------------------------------------------------------------ modal plumbing
func _open_modal(title: String, width := 980.0, danger := false) -> VBoxContainer:
	_close_modal()
	modal_token += 1
	modal = Control.new()
	modal.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal.theme = (get_child(0) as Control).theme
	add_child(modal)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal.add_child(dim)
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal.add_child(cc)
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(width, 0)
	if danger:
		var sb: StyleBoxFlat = modal.theme.get_stylebox("panel", "PanelContainer").duplicate()
		sb.border_color = Color("#d04a3a")
		sb.set_border_width_all(3)
		p.add_theme_stylebox_override("panel", sb)
	cc.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	v.add_child(_label(title, 22, Color("#ff8a7a") if danger else COL_ACCENT))
	return v

func _close_modal() -> void:
	if modal:
		modal.queue_free()
		modal = null

func _show_intro() -> void:
	var v := _open_modal("Era of Savagery — POC")
	var r := _rich(0, true)
	r.text = """You are the [color=#ffd36b]Great Chieftain[/color]. This prototype demonstrates the three-tier control hierarchy:

[color=#ffd36b]Tier 1 · Direct micro[/color] — select tribespeople (click / drag) and right-click trees, bushes, deer, tigers, construction sites or ground.
[color=#ffd36b]Tier 2 · Task Contracts[/color] — select one person (try [b]Panshi[/b], [b]Alie[/b] or [b]Linghe[/b]) and press [i]Assign Task Contract[/i]. Their LLM persona negotiates a blueprint for a settlement across the river. Once sealed, a deterministic state machine executes it with [b]zero LLM calls[/b] (watch the counter in the top bar) — until an ambush re-awakens the leader.
[color=#ffd36b]Tier 3 · Vice-Chieftains[/color] — appoint a Steward to auto-manage idle villagers.
[color=#ffd36b]Exploration[/color] — the land beyond the firelight is hidden. Select someone and press [b]X[/b] (or [i]Scout the unknown[/i]) to auto-explore; landmarks reward the finder with lore, food or wood and a new memory. Beware the saber-tooth dens in the far east. The minimap (bottom left) shows what you know: click it to look, right-click it to send the selected people.

[color=#ffd36b]Evolution[/color] — new wisdom comes from [i]practice[/i] (chopping wood teaches stone tools, rituals lead to totems) or from lore and research contracts. Each age changes homes, gear and what people can do; the tribe's culture drifts with its deeds and adopts traditions. Knowledge lives in people until it is carved into totems or laws.
Every task grants specialization XP and notable events enter each person's [b]Memory Archive[/b], which is fed back into their next negotiation. Research the Wisdom Tree with lore from rituals. Milestone events: the Great Flood (Day %d), Overpopulation (%d people), Birth of the Chosen One (100%% devotion).

LLM node: [color=#9fd0ff]%s[/color]. Open [i]LLM Settings[/i] to use DeepSeek or GLM with your API key.""" % [D.FLOOD_DAY, D.OVERPOP_THRESHOLD, llm.label()]
	v.add_child(r)
	v.add_child(_button("Begin", _close_modal))

# ------------------------------------------------------------ Phase 1: negotiation
var neg := {}

func _start_contract_for_selected() -> void:
	var sel: Array = world.selected_units()
	if sel.size() == 1: open_negotiation(sel[0])

func open_negotiation(leader, kind := "settle") -> void:
	var tr: Array = []
	for t in leader.traits: tr.append(D.TRAITS[t]["name"])
	var research: bool = kind == "research"
	var v := _open_modal(("RESEARCH CONTRACT · Seeking new wisdom with %s" if research else "TASK CONTRACT · Phase 1: Negotiation with %s") % leader.name, 1080)
	var token := modal_token
	var max_crew := mini(4 if research else 5, sim.contracts.available_helpers(leader.id).size() + 1)
	neg = {"leader": leader, "kind": kind, "history": [], "bp": {}, "raw": {}, "terms_set": false, "syncing": false, "busy": false, "calls": 0, "token": token}
	v.add_child(_label("%s \"%s\" · %s · Lv%d · Craft %d / Combat %d / Lore %d · HP %d/%d" % [leader.name, leader.epithet, ", ".join(tr), sim.unit_level(leader), leader.lv("craft"), leader.lv("combat"), leader.lv("lore"), leader.hp, leader.max_hp], 14, Color("#e6b8ff")))
	var dh := HBoxContainer.new()
	v.add_child(dh)
	dh.add_child(_label("Directive:", 15, COL_DIM))
	var directive := LineEdit.new()
	directive.text = "Find new wisdom for the tribe" if research else "Establish a settlement across the river"
	directive.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dh.add_child(directive)
	neg["directive"] = directive
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	v.add_child(cols)
	var lcol := VBoxContainer.new()
	lcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lcol.size_flags_stretch_ratio = 1.3
	cols.add_child(lcol)
	var rcol := VBoxContainer.new()
	rcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(rcol)
	lcol.add_child(_header("NEGOTIATION"))
	var chat := _rich(330)
	chat.scroll_following = true
	lcol.add_child(chat)
	neg["chat"] = chat
	var rh := HBoxContainer.new()
	lcol.add_child(rh)
	var reply := LineEdit.new()
	reply.placeholder_text = ("Reply to %s… (e.g. 'seek farming instead', 'be quick about it')" if research else "Reply to %s… (e.g. 'make it bigger', 'skip the wall', 'focus on fishing')") % leader.name
	reply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rh.add_child(reply)
	neg["reply"] = reply
	var send := _button("Send", func(): _neg_send())
	rh.add_child(send)
	reply.text_submitted.connect(func(_t): _neg_send())

	rcol.add_child(_header("CHIEFTAIN'S TERMS"))
	var g := GridContainer.new()
	g.columns = 2
	rcol.add_child(g)
	g.add_child(_label("Crew size (incl. leader)", 14, COL_DIM))
	var crew := SpinBox.new()
	crew.min_value = 1
	crew.max_value = max_crew
	g.add_child(crew)
	neg["crew"] = crew
	var mark := func(_v):
		if not neg.get("syncing", false): neg["terms_set"] = true
	crew.value_changed.connect(mark)
	if research:
		g.add_child(_label("Wisdom to seek", 14, COL_DIM))
		var tech := OptionButton.new()
		tech.add_item("Let %s choose" % leader.name)
		var ids: Array = [""]
		for id in sim.evo.candidates():
			tech.add_item("%s (%d%% understood)" % [sim.evo.tech_def(id)["name"], roundi(sim.evo.insight_frac(id) * 100)])
			ids.append(id)
		g.add_child(tech)
		neg["tech"] = tech
		neg["tech_ids"] = ids
		tech.item_selected.connect(mark)
	else:
		g.add_child(_label("Capacity target", 14, COL_DIM))
		var cap := SpinBox.new()
		cap.min_value = 2
		cap.max_value = 15
		g.add_child(cap)
		g.add_child(_label("Focus", 14, COL_DIM))
		var focus := OptionButton.new()
		for f in D.FOCUSES: focus.add_item(f)
		g.add_child(focus)
		neg["cap"] = cap
		neg["focus"] = focus
		cap.value_changed.connect(mark)
		focus.item_selected.connect(mark)
	rcol.add_child(_button("Ask %s to revise with these terms" % leader.name, func(): _neg_request("")))
	var bph := HBoxContainer.new()
	rcol.add_child(bph)
	var hdr := _header("THE PLAN")
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bph.add_child(hdr)
	var jt := CheckButton.new()
	jt.text = "Show JSON"
	jt.add_theme_font_size_override("font_size", 12)
	jt.focus_mode = Control.FOCUS_NONE
	jt.toggled.connect(func(on):
		neg["show_json"] = on
		if neg.has("san"): _neg_show_bp(neg["san"]))
	bph.add_child(jt)
	neg["show_json"] = false
	var bpv := _rich(300)
	rcol.add_child(bpv)
	neg["bpview"] = bpv
	var status := _label("", 13, Color("#9fd0ff"))
	v.add_child(status)
	neg["status"] = status
	var bh := HBoxContainer.new()
	bh.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(bh)
	var confirm := _button("Seal the Contract", func(): _neg_confirm())
	confirm.disabled = true
	neg["confirm"] = confirm
	bh.add_child(_button("Cancel", func(): _close_modal(); sim.paused = false))
	bh.add_child(confirm)
	sim.paused = true
	_neg_request("")

func _neg_terms() -> Dictionary:
	if neg.get("kind", "settle") == "research":
		return {"kind": "research", "crew_size": int(neg["crew"].value), "tech": neg["tech_ids"][neg["tech"].selected]}
	return {"crew_size": int(neg["crew"].value), "capacity_target": int(neg["cap"].value), "focus": neg["focus"].get_item_text(neg["focus"].selected)}

func _neg_send() -> void:
	var msg: String = neg["reply"].text.strip_edges()
	if msg == "" or neg["busy"]: return
	neg["reply"].text = ""
	neg["history"].append({"speaker": "Chieftain", "text": msg})
	neg["chat"].append_text("\n[color=#ffd36b][b]You:[/b][/color] %s\n" % msg)
	_neg_request(msg)

func _neg_request(msg: String) -> void:
	if neg["busy"]: return
	neg["busy"] = true
	var token: int = neg["token"]
	var leader = neg["leader"]
	neg["confirm"].disabled = true
	neg["status"].text = "Awakening %s's LLM persona core (%s)…" % [leader.name, llm.label()]
	neg["chat"].append_text("[color=#8a7a60][i]%s is thinking…[/i][/color]\n" % leader.name)
	var ctx: Dictionary = sim.contracts.negotiation_ctx(leader, neg["directive"].text, _neg_terms(), neg["terms_set"], msg, neg["raw"], neg["history"].slice(-6), neg.get("kind", "settle"))
	var r: Dictionary = await llm.negotiate(ctx)
	var chat: RichTextLabel = neg["chat"]
	chat.remove_paragraph(chat.get_paragraph_count() - 2) # drop the "is thinking…" line
	if modal == null or modal_token != token: return
	neg["calls"] += 1
	var san: Dictionary = sim.contracts.sanitize(r.get("blueprint"), _neg_terms(), leader)
	var note := ""
	if not san["ok"]:
		var fb := Persona.propose(ctx)
		r["speech"] = fb["speech"] if r.get("speech", "") == "" else r["speech"]
		r["blueprint"] = fb["blueprint"]
		san = sim.contracts.sanitize(fb["blueprint"], _neg_terms(), leader)
		note = " · blueprint invalid, engine substituted a safe plan"
	if not san["ok"]:
		neg["chat"].append_text("[color=#ff8a7a][i]%s[/i][/color]\n" % " ".join(san["notes"]))
		neg["status"].text = "No valid plan is possible right now."
		neg["busy"] = false
		return
	neg["raw"] = r["blueprint"] if r["blueprint"] is Dictionary else san["blueprint"]
	neg["bp"] = san["blueprint"]
	neg["history"].append({"speaker": leader.name, "text": r["speech"]})
	neg["chat"].append_text("[color=#e6b8ff][b]%s:[/b][/color] %s\n" % [leader.name, r["speech"]])
	if r.get("error", "") != "":
		neg["chat"].append_text("[color=#ff8a7a][i](cloud LLM failed: %s — used offline persona)[/i][/color]\n" % r["error"])
	_neg_sync_terms(san["blueprint"])
	_neg_show_bp(san)
	neg["status"].text = "LLM node: %s · %d call(s) this negotiation%s. Adjust terms or reply, then seal." % [r.get("source", "?"), neg["calls"], note]
	neg["confirm"].disabled = false
	neg["busy"] = false

func _neg_sync_terms(bp: Dictionary) -> void:
	neg["syncing"] = true
	neg["crew"].value = bp["crew_size"]
	if neg.get("kind", "settle") == "research":
		var i: int = neg["tech_ids"].find(bp.get("tech", ""))
		if i > 0: neg["tech"].select(i)
	else:
		neg["cap"].value = bp["capacity_target"]
		neg["focus"].select(D.FOCUSES.find(bp["focus"]))
	neg["syncing"] = false

func _neg_show_bp(san: Dictionary) -> void:
	neg["san"] = san
	var bp: Dictionary = san["blueprint"]
	var s := "[color=#ffd36b]%s[/color] · crew %d · houses %d (target %d) · wood ≈ %d\n" % [bp["plan_id"], bp["crew_size"], sim.contracts.housing(bp), bp["capacity_target"], sim.contracts.wood_needed(bp)]
	if bp.get("kind", "settle") == "research":
		var td: Dictionary = sim.evo.tech_def(bp["tech"])
		s = "[color=#ffd36b]%s[/color] · seeking [color=#c8a8ff]%s[/color] (%d%% understood) · crew %d\n[color=#b8a888]%s[/color]\n" % [bp["plan_id"], td["name"], roundi(sim.evo.insight_frac(bp["tech"]) * 100), bp["crew_size"], td["desc"]]
	var i := 1
	for st in bp["steps"]:
		s += " %d. %s\n" % [i, sim.contracts.step_text(st)]
		i += 1
	s += "[color=#ff9b7a]abort on:[/color] %s\n" % ", ".join(bp["abort_conditions"])
	for n in san["notes"]: s += "[color=#ff8a7a]⚠ %s[/color]\n" % n
	if neg.get("show_json", false): s += "\n[color=#7a8a98][code]%s[/code][/color]" % JSON.stringify(bp, "  ")
	neg["bpview"].text = s

func _neg_confirm() -> void:
	if neg["bp"].is_empty() or neg["busy"]: return
	var leader = neg["leader"]
	sim.contracts.create(neg["bp"], leader, neg["directive"].text)
	_close_modal()
	sim.paused = false
	world.select_only(leader)

# ------------------------------------------------------------ Phase 4: emergency awakening
func _on_interrupt(c) -> void:
	var ld = sim.unit_by_id(c.leader_id)
	var sm: Dictionary = sim.contracts.summary(c)
	var v := _open_modal("⚠ EMERGENCY AWAKENING · %s" % c.plan["plan_id"], 900, true)
	var token := modal_token
	world.focus_on(c.site)
	var info := _rich(0, true)
	info.text = "[color=#ff9b7a]Abort condition:[/color] %s   [color=#b8a888]Progress:[/color] %d%%   [color=#b8a888]Threat:[/color] %s\n[color=#b8a888]Built:[/color] %s   [color=#b8a888]Half-built:[/color] %s\n[color=#b8a888]Crew:[/color] %s" % [
		sm["reason"], sm["progress_pct"], sm["threat"], ", ".join(sm["built"]) if not sm["built"].is_empty() else "—",
		", ".join(sm["half_built"]) if not sm["half_built"].is_empty() else "—", ", ".join(sm["crew"])]
	v.add_child(info)
	var speech := _rich(0, true)
	speech.text = "[color=#8a7a60][i]The state machine has halted. Re-awakening %s's LLM node…[/i][/color]" % ld.name
	v.add_child(speech)
	var opts := VBoxContainer.new()
	v.add_child(opts)
	var r: Dictionary = await llm.emergency(sim.contracts.emergency_ctx(c))
	if modal == null or modal_token != token: return
	speech.text = "[color=#e6b8ff][b]%s:[/b][/color] %s\n[color=#8a9aa8](%s)%s[/color]" % [ld.name, r["speech"], r.get("source", ""), (" — cloud error: " + r["error"]) if r.get("error", "") != "" else ""]
	for o in r["options"]:
		var eff: String = o["effect"]
		var b := _button("%s   [%s]" % [o["label"], sim.contracts.EFFECTS.get(eff, eff)], func():
			sim.contracts.resolve(c, eff, o["label"])
			_close_modal()
			sim.paused = false)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		opts.add_child(b)

func _toast_contract_done(c) -> void:
	if modal: return
	var v := _open_modal("Task Contract Complete · %s" % c.plan["plan_id"], 700)
	var ld = sim.unit_by_id(c.leader_id)
	var r := _rich(0, true)
	r.text = "%s's crew has finished every step of the blueprint. The outpost now houses up to %d more tribespeople.\n\nThe contract was executed by the deterministic state machine. LLM calls: [color=#9fd0ff]1 negotiation + %d emergency awakening(s)[/color]. The outcome has been archived in each crew member's Memory Archive." % [ld.name if ld else "The", sim.contracts.housing(c.plan), c.interruptions]
	v.add_child(r)
	var was_paused: bool = sim.paused
	sim.paused = true
	v.add_child(_button("Continue", func(): _close_modal(); sim.paused = was_paused))

# ------------------------------------------------------------ milestone events
func _on_event(id: String) -> void:
	var d: Dictionary = sim.event_def(id)
	var v := _open_modal("☼ " + d["title"], 820)
	var txt := _rich(0, true)
	txt.text = "[i]%s[/i]" % d["text"]
	v.add_child(txt)
	var i := 0
	for o in d["options"]:
		var idx := i
		var b := _button("%s — %s" % [o["label"], o["desc"]], func(): _event_choose(id, idx))
		b.disabled = not o["enabled"]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(b)
		i += 1

func _event_choose(id: String, idx: int) -> void:
	var r: Dictionary = sim.resolve_event(id, idx)
	var v := _open_modal("Outcome", 700)
	var txt := _rich(0, true)
	txt.text = r["text"]
	v.add_child(txt)
	if r["open_contract"]:
		v.add_child(_label("Choose the expedition leader:", 15, COL_DIM))
		var cands: Array = sim.contracts.available_helpers()
		cands.sort_custom(func(a, b): return sim.unit_level(a) > sim.unit_level(b))
		for u in cands.slice(0, 5):
			var tr: String = D.TRAITS[u.traits[0]]["name"]
			v.add_child(_button("%s \"%s\" — %s, Lv%d" % [u.name, u.epithet, tr, sim.unit_level(u)], func(): open_negotiation(u)))
	v.add_child(_button("Continue", func(): _close_modal(); sim.paused = false))

# ------------------------------------------------------------ tech tree
func _open_tech() -> void:
	var v := _open_modal("WISDOM & CULTURE · %s · Lore: %d" % [D.ERA_NAMES[sim.evo.era], sim.stock["lore"]], 1240)
	var was_paused: bool = sim.paused
	sim.paused = true
	var note := "Knowledge is [color=#b6f28a]codified[/color] - it can no longer be lost." if sim.evo.codified else \
		("Knowledge is [color=#ff9b7a]oral[/color]: a tech dies with its last keeper. Megalithic Totems or a Tribal Code would preserve it." if sim.evo.oral_tradition else "Oral tradition is off.")
	var hint := _rich(0, true)
	hint.text = "New wisdom grows from [i]practice[/i] (the bar fills as people do related work) and can be finished with lore or a research contract. " + note
	v.add_child(hint)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	v.add_child(h)
	for era in [1, 2, 3]:
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(col)
		col.add_child(_header(D.ERA_NAMES[era].to_upper()))
		for tdef in D.TECHS:
			if tdef["era"] != era: continue
			col.add_child(_tech_card(tdef, was_paused))
	v.add_child(_header("CULTURE · %s" % sim.evo.culture_summary().capitalize()))
	var cg := HBoxContainer.new()
	cg.add_theme_constant_override("separation", 16)
	v.add_child(cg)
	var axes := _rich(0, true)
	axes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var at := ""
	for a in D.CULTURE_AXES:
		var val: float = sim.evo.culture[a]
		var pos := clampi(int(round((val + 100.0) / 200.0 * 20.0)), 0, 20)
		var bar := ""
		for i in 21:
			bar += "[color=#ffd36b]●[/color]" if i == pos else ("[color=#5a4a38]|[/color]" if i == 10 else "[color=#3a3226]─[/color]")
		at += "%s %s %s  [color=#8a7a60](%+d)[/color]\n" % [_pad(D.CULTURE_AXES[a][1], 9), bar, _pad(D.CULTURE_AXES[a][0], 9), roundi(val)]
	axes.text = "[font_size=14]" + at + "[/font_size][color=#8a7a60]Values drift with deeds: hunting and scouting make the tribe roam, fields settle it; kills harden it, rituals turn it to the spirits, Vice-Chieftains rank it, shared meals bind it.[/color]"
	cg.add_child(axes)
	var trads := _rich(0, true)
	trads.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tt := "[color=#ffd36b]TRADITIONS[/color] [color=#8a7a60](adopted at ±%d)[/color]\n" % D.TRADITION_THRESHOLD
	for t in D.TRADITIONS:
		var pole: String = D.CULTURE_AXES[t["axis"]][0 if t["sign"] > 0 else 1]
		if sim.evo.has_trad(t["id"]):
			tt += "[color=#b6f28a]✔ %s[/color] (Day %d) - %s\n" % [t["name"], sim.evo.traditions[t["id"]], t["desc"]]
		else:
			tt += "[color=#6a5a48]○ %s - needs %s[/color]\n" % [t["name"], pole]
	trads.text = tt
	cg.add_child(trads)
	v.add_child(_button("Close", func(): _close_modal(); sim.paused = was_paused))

func _pad(s2: String, n: int) -> String:
	return s2 + " ".repeat(maxi(0, n - s2.length()))

func _tech_card(tdef: Dictionary, was_paused: bool) -> Control:
	var id: String = tdef["id"]
	var known: bool = sim.has_tech(id)
	var reachable: bool = sim.evo.prereqs_met(id)
	var p := PanelContainer.new()
	var pv := VBoxContainer.new()
	p.add_child(pv)
	pv.add_child(_label(tdef["name"], 16, Color("#b6f28a") if known else (COL_ACCENT if reachable else Color("#8a7a60"))))
	pv.add_child(_label(tdef["desc"], 13, COL_DIM))
	var info := _rich(0, true)
	var how: Array = []
	for k in tdef["practice"]: how.append(D.PRACTICE_NAMES[k])
	if known:
		var keepers: int = sim.evo.keepers(id).size()
		var by: String = (" · invented by " + sim.evo.inventors[id]) if sim.evo.inventors.has(id) else ((" · taught by " + sim.evo.teachers[id]) if sim.evo.teachers.has(id) else "")
		info.text = "[color=#b6f28a]Known[/color]%s · %d keeper%s" % [by, keepers, "" if keepers == 1 else "s"]
	else:
		var frac: float = sim.evo.insight_frac(id)
		var bars := int(frac * 14)
		info.text = "[bgcolor=#8a6ad0]%s[/bgcolor][bgcolor=#3a3226]%s[/bgcolor] %d%% understood\n[color=#8a7a60]Learned by %s[/color]" % [" ".repeat(bars * 2), " ".repeat((14 - bars) * 2), roundi(frac * 100), ", ".join(how)]
		if not reachable:
			var names: Array = []
			for rq in tdef["req"]:
				if not sim.has_tech(rq): names.append(sim.evo.tech_def(rq)["name"])
			info.text += "\n[color=#8a7a60]Requires %s[/color]" % ", ".join(names)
	pv.add_child(info)
	if not known:
		var cost: int = sim.evo.lore_cost(id)
		var b := _button("Teach now (%d lore)" % cost, func():
			var err: String = sim.research(id)
			if err == "":
				_close_modal()
				sim.paused = was_paused
				_open_tech()
			else: sim.popup(D.VILLAGE, err, Color("#ff8080")))
		b.disabled = not reachable or sim.stock["lore"] < cost
		pv.add_child(b)
	return p

# ------------------------------------------------------------ settings
func _open_settings() -> void:
	var v := _open_modal("LLM NODE SETTINGS", 760)
	var was_paused: bool = sim.paused
	sim.paused = true
	v.add_child(_label("The LLM is only called at contract nodes (negotiation and emergency awakening) — never per frame. Any OpenAI-compatible endpoint works.", 14, COL_DIM))
	var g := GridContainer.new()
	g.columns = 2
	v.add_child(g)
	g.add_child(_label("Provider", 15, COL_DIM))
	var prov := OptionButton.new()
	for k in llm.PRESET_ORDER: prov.add_item(llm.PRESETS[k]["label"])
	prov.select(llm.PRESET_ORDER.find(llm.provider))
	g.add_child(prov)
	g.add_child(_label("Base URL", 15, COL_DIM))
	var url := LineEdit.new()
	url.text = llm.base_url
	url.custom_minimum_size = Vector2(480, 0)
	g.add_child(url)
	g.add_child(_label("Model", 15, COL_DIM))
	var mdl := LineEdit.new()
	mdl.text = llm.model
	g.add_child(mdl)
	g.add_child(_label("API key", 15, COL_DIM))
	var key := LineEdit.new()
	key.secret = true
	key.text = llm.api_key
	key.placeholder_text = "sk-…  (or set DEEPSEEK_API_KEY / ZHIPU_API_KEY / LLM_API_KEY)"
	g.add_child(key)
	prov.item_selected.connect(func(i):
		var k: String = llm.PRESET_ORDER[i]
		url.text = llm.PRESETS[k]["base_url"]
		mdl.text = llm.PRESETS[k]["model"])
	var amb := CheckBox.new()
	amb.text = "Scripted mid-task ambush (at ~45% contract progress)"
	amb.button_pressed = sim.scripted_ambush
	amb.toggled.connect(func(on): sim.scripted_ambush = on)
	v.add_child(amb)
	var fog := CheckBox.new()
	fog.text = "Fog of war (unexplored land is hidden until scouted)"
	fog.button_pressed = sim.fog_enabled
	fog.toggled.connect(func(on): sim.fog_enabled = on)
	v.add_child(fog)
	var oral := CheckBox.new()
	oral.text = "Oral tradition (a tech is lost if everyone who knows it dies before it is codified)"
	oral.button_pressed = sim.evo.oral_tradition
	oral.toggled.connect(func(on): sim.evo.oral_tradition = on)
	v.add_child(oral)
	var result := _label("", 14, Color("#9fd0ff"))
	v.add_child(result)
	var apply := func():
		llm.provider = llm.PRESET_ORDER[prov.selected]
		llm.base_url = url.text.strip_edges()
		llm.model = mdl.text.strip_edges()
		llm.api_key = key.text.strip_edges()
		if llm.api_key == "": llm.api_key = llm.env_key()
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(h)
	h.add_child(_button("Test connection", func():
		apply.call()
		if not llm.is_online():
			result.text = "Offline persona engine needs no connection."
			return
		result.text = "Testing…"
		var msg: String = await llm.test_connection()
		if is_instance_valid(result): result.text = msg))
	h.add_child(_button("Save & close", func():
		apply.call()
		llm.save_settings()
		_close_modal()
		sim.paused = was_paused))
	v.add_child(_label("Key is stored only in this machine's Godot user data folder (not in the project).", 12, Color("#8a7a60")))
