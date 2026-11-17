## HUD and modals, built in code. Owns the async flows that wake the LLM node:
## Phase 1 negotiation and Phase 4 emergency awakening.
extends CanvasLayer

const D = preload("res://scripts/data.gd")
const Persona = preload("res://scripts/persona_engine.gd")

const WV = preload("res://scripts/world_view.gd")
const I = preload("res://scripts/i18n.gd")
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
var log_tabs: TabContainer
var map_tip: PanelContainer
var map_tip_text: RichTextLabel
var tip_t := 0.0
var clans_text: RichTextLabel
var log_text: RichTextLabel
var policy_opt: OptionButton
var audio # audio.gd (set by main; null in tests)
var game # main.gd: save_to(), load_from() (null in tests)
var build_btns := {}
var modal: Control = null
# ---- achievement celebrations (one dialog per first, queued; see _show_feat)
var feat_popups := true # the player can switch them off; the screenshot harness does
var feat_queue: Array = []
var feat_token := -1 # modal_token of the open achievement dialog (-1: none)
var feat_resume = null # sim.paused before the first dialog of a run
var snap_vp: SubViewport
var snap_cam: Camera2D
var modal_token := 0
var refresh_t := 0.0
var log_dirty := true
var roster_sig := ""
var roster_headers := {} # group key -> Button
var roster_bar: HBoxContainer
var roster_mode := "quest" # "quest" (grouped by what people are doing) or "ability" (sortable table)
var sort_key := "lv"
var sort_desc := true
const SORT_COLS := [["lv", "Lv", "Overall level"], ["forage", "Fo", "Foraging & Hunting"], ["craft", "Cr", "Crafting & Building"], ["combat", "Co", "Combat & Leadership"], ["lore", "Lo", "Shamanism & Lore"], ["trade", "Tr", "Trade & Barter"]]
const COL_W := 38.0
var sheet_scout_btn: Button
var sheet_research_btn: Button
var sheet_envoy_btn: Button
var sheet_war_btn: Button
var clans_btns: HFlowContainer
var clans_sig := ""
var reno_btn: Button
var lang_btn: Button
var alert_box: VBoxContainer
var alert_items: Array = [] # [Control, expires_at_msec]
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
	_build_alerts(root)
	sim.log_added.connect(func(): log_dirty = true)
	sim.contract_interrupted.connect(_on_interrupt)
	sim.event_fired.connect(_on_event)
	sim.envoy_arrived.connect(open_parley)
	sim.contract_finished.connect(func(c): _toast_contract_done(c))
	sim.alert_raised.connect(_on_alert)
	sim.feat_added.connect(_on_feat)
	sim.advice_wanted.connect(_on_advice_wanted)
	feat_popups = _feat_pref()
	world.selection_changed.connect(_refresh_left)
	world.structure_clicked.connect(func(s): if s.type == "burial_ground": open_graves(s))
	_refresh_left()
	_show_intro()

## The Steward weighs which improvement to build: ask its LLM node (offline: the rules'
## first choice, at once). The answer goes through the same operation a game master uses.
func _on_advice_wanted(ctx: Dictionary) -> void:
	if not llm.is_online():
		sim.improve.choose("", "")
		return
	var r: Dictionary = await llm.advise_build(ctx)
	sim.improve.choose(str(r.get("choice", "")), str(r.get("speech", "")), str(r.get("source", "")))

func modal_open() -> bool:
	return modal != null

# ------------------------------------------------------------ theme & helpers
static func _make_theme() -> Theme:
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
# ------------------------------------------------------------ alerts (AoE-style banners)
func _build_alerts(root: Control) -> void:
	alert_box = VBoxContainer.new()
	alert_box.anchor_left = 0.5
	alert_box.anchor_right = 0.5
	alert_box.offset_left = -380
	alert_box.offset_right = 380
	alert_box.offset_top = 62
	alert_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	alert_box.add_theme_constant_override("separation", 4)
	root.add_child(alert_box)

func _on_alert(a: Dictionary) -> void:
	var col: Color = {"danger": Color("#ff8a7a"), "warn": Color("#ffd36b")}.get(a["level"], Color("#cfe8ff"))
	var b := _button(("⚠ " if a["level"] == "danger" else "") + a["text"], func():
		if a["pos"] != Vector2.ZERO: world.focus_on(a["pos"]), tr("Click to look") if a["pos"] != Vector2.ZERO else "")
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_color_override("font_color", col)
	b.add_theme_font_size_override("font_size", 16)
	b.focus_mode = Control.FOCUS_NONE
	alert_box.add_child(b)
	alert_items.append([b, Time.get_ticks_msec() + (9000 if a["level"] == "danger" else 6000)])
	while alert_items.size() > 3:
		alert_items[0][0].queue_free()
		alert_items.pop_front()

## A short note in the banner area (not written to the chronicle).
func toast(text: String) -> void:
	_on_alert({"level": "info", "text": text, "pos": Vector2.ZERO})

## After a game is loaded: bring back the decision that was open, if any.
func after_load() -> void:
	if sim.pending_event != "": _on_event(sim.pending_event)
	else:
		for c in sim.contracts.list:
			if c.status == "interrupted":
				_on_interrupt(c)
				break
	toast(tr("Game loaded: Day %d") % sim.day())

func _expire_alerts() -> void:
	var now := Time.get_ticks_msec()
	for it in alert_items.duplicate():
		if now > it[1]:
			it[0].queue_free()
			alert_items.erase(it)

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
	top_stats.custom_minimum_size = Vector2(0, 38)
	top_stats.add_theme_font_size_override("normal_font_size", 13)
	top_stats.add_theme_font_size_override("bold_font_size", 13)
	top_stats.add_theme_constant_override("line_separation", -2)
	top_stats.scroll_active = false
	h.add_child(top_stats)
	pause_btn = _button("Pause", func(): sim.paused = not sim.paused, "Space")
	h.add_child(pause_btn)
	for sp in [1, 2, 4]:
		var b := _button(tr("%dx") % sp, func(): sim.speed = sp)
		speed_btns.append(b)
		h.add_child(b)
	h.add_child(_button("Wisdom & Culture", _open_tech, "T: what the tribe knows, how it is learning, and who it is becoming"))
	h.add_child(_button("Legacy", _open_legacy, "The three paths to victory: conquest, unity and wisdom"))
	h.add_child(_button("Achievements", open_achievements, "The tribe's inventions and everything it did first"))
	if sim.cult.on(): h.add_child(_button("Heritage", open_heritage, "Your people's history and legends: tools, foods, people, happenings and folk tales"))
	h.add_child(_button("LLM Settings", _open_settings))
	h.add_child(_button("Sound", _open_sound, "Music, sound effects and the sounds of the land"))
	h.add_child(_button("Save / Load", open_saves, "F5: quick save · F9: quick load"))
	lang_btn = _button(I.LANGS["en" if I.is_zh() else "zh"], _toggle_lang, "Language / 语言")
	h.add_child(lang_btn)
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
	roster_bar = HBoxContainer.new()
	v.add_child(roster_bar)
	var grp := ButtonGroup.new()
	for m in [["quest", "By quest", "Group people under the quest they are on"], ["ability", "By ability", "A sortable table of everyone's capabilities"]]:
		var mb := _button(m[1], func():
			roster_mode = m[0]
			_refresh_left(), m[2])
		mb.toggle_mode = true
		mb.button_group = grp
		mb.button_pressed = m[0] == roster_mode
		mb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mb.focus_mode = Control.FOCUS_NONE
		roster_bar.add_child(mb)
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
	sheet_envoy_btn = _button("Send as envoy…", func():
		var sel: Array = world.selected_units()
		if sel.size() == 1: open_envoy(sel[0], ""), "Diplomacy: walk to a neighbouring clan and parley with its chieftain")
	sheet_box.add_child(sheet_envoy_btn)
	sheet_war_btn = _button("Lead a war party…", func():
		var sel: Array = world.selected_units()
		if sel.size() == 1: open_negotiation(sel[0], "war"), "Tier 2: a war Task Contract against a neighbouring clan - the leader plans the raid")
	sheet_box.add_child(sheet_war_btn)
	var hb := HBoxContainer.new()
	sheet_box.add_child(hb)
	sheet_steward_btn = _button("Appoint Steward", func(): _appoint("steward"), "Tier 3: auto-manages idle villagers")
	sheet_chief_btn = _button("Appoint War Chief", func(): _appoint("warchief"), "Tier 3: rallies warriors vs. beasts near the village")
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
	mm.draw_texture_rect(world.minimap_tex, Rect2(0, 0, D.W, D.H), false)
	if sim.fog_enabled: mm.draw_texture_rect(world.fog_tex, Rect2(0, 0, sim.fog_w * D.FOG_CELL, sim.fog_h * D.FOG_CELL), false)
	mm.draw_set_transform_matrix(Transform2D.IDENTITY)
	for st in sim.structures:
		if not sim.is_explored(st.pos): continue
		var rc: String = sim.rivals.owner_clan(st.owner)
		mm.draw_rect(Rect2(_mm_pt(WV.iso(st.pos)) - Vector2(2, 2), Vector2(4, 4)), Color("#c9a24f") if rc == "" else sim.rivals.clans[rc]["color"])
	for lm in sim.landmarks:
		if lm["found"]:
			var q := _mm_pt(WV.iso(lm["pos"]))
			mm.draw_colored_polygon(PackedVector2Array([q + Vector2(0, -4), q + Vector2(4, 0), q + Vector2(0, 4), q + Vector2(-4, 0)]), Color("#ff6b5a") if lm["kind"] == "den" else Color("#ffe066"))
	for pr in sim.predators:
		if not pr.dead and not pr.fled and sim.is_visible(pr.pos):
			mm.draw_circle(_mm_pt(WV.iso(pr.pos)), 2.5, Color("#ff4a3a") if pr.kind not in ["hunter", "trader"] else sim.rivals.clans[pr.clan]["color"].lightened(0.3))
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
		var b := _button(tr("%s (%s)") % [tr(sd["name"]), _cost_short(sd)], func(): world.build_type = k, tr("Costs %s") % _cost_long(sd))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART # room for "Requires <wisdom>" hints
		b.custom_minimum_size = Vector2(60, 0)
		build_btns[k] = b
		grid.add_child(b)
	reno_btn = _button("", func():
		var free: Array = world.selected_units().filter(func(u): return u.role != "contract")
		var err: String = sim.renovate(free)
		if err != "": sim.popup(D.VILLAGE, tr(err), Color("#ff8080")), "Rebuild old homes and walls in the current era's style")
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
	var auto := CheckBox.new()
	auto.text = tr("Steward lays out improvements")
	auto.tooltip_text = tr("The Steward plans new buildings when the village needs them (a Granary when the stores fill up, a Hut when beds run short...) and pays for them from the stockpile. With an LLM node the Steward chooses between them.")
	auto.button_pressed = sim.improve.on
	auto.toggled.connect(func(b): sim.improve.on = b)
	v.add_child(auto)
	v.add_child(_header("NEIGHBORING CLANS"))
	clans_text = _rich(0, true)
	v.add_child(clans_text)
	clans_btns = HFlowContainer.new()
	v.add_child(clans_btns)
	# The chronicle and the Task Contracts share the rest of the panel as two tabs.
	log_tabs = TabContainer.new()
	log_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_tabs.custom_minimum_size = Vector2(0, 200)
	v.add_child(log_tabs)
	log_text = _rich(0)
	log_text.name = "Chronicle"
	log_text.meta_clicked.connect(_on_log_link)
	log_text.meta_underlined = false
	log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_tabs.add_child(log_text)
	contracts_text = _rich(0)
	contracts_text.name = "Contracts"
	contracts_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_tabs.add_child(contracts_text)
	log_tabs.set_tab_title(0, tr("Chronicle"))
	v.add_child(_label("LMB select/drag · RMB command (tree/bush/deer = gather, tiger = attack, site = build) · pan: WASD / screen edge / MMB drag / two-finger swipe · zoom: wheel / pinch · Space pause · F11 fullscreen", 12, COL_DIM))

## A small panel by the cursor naming what is under it on the map.
func _map_tip(delta: float) -> void:
	if map_tip == null:
		map_tip = PanelContainer.new()
		map_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		map_tip.theme = (get_child(0) as Control).theme
		map_tip_text = _rich(0, true)
		map_tip_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		map_tip_text.custom_minimum_size = Vector2(300, 0)
		map_tip.add_child(map_tip_text)
		add_child(map_tip)
		map_tip.visible = false
	tip_t -= delta
	if tip_t <= 0:
		tip_t = 0.12
		var info: Array = world.hover_info() if not modal_open() else []
		map_tip.visible = not info.is_empty()
		if map_tip.visible: map_tip_text.text = "[b][color=#ffd36b]%s[/color][/b]\n[font_size=13]%s[/font_size]" % [info[0], info[1]]
	if map_tip.visible:
		var mp := get_viewport().get_mouse_position() + Vector2(18, 20)
		var vs := get_viewport().get_visible_rect().size
		map_tip.reset_size()
		mp.x = minf(mp.x, vs.x - map_tip.size.x - 6)
		mp.y = minf(mp.y, vs.y - map_tip.size.y - 6)
		map_tip.position = mp

# ------------------------------------------------------------ periodic refresh
func _process(delta: float) -> void:
	if minimap: minimap.queue_redraw()
	_feat_tick()
	_map_tip(delta)
	_expire_alerts()
	refresh_t -= delta
	if refresh_t > 0: return
	refresh_t = 0.25
	_refresh_top()
	_refresh_left_content()
	_refresh_right()

func _refresh_top() -> void:
	var f: float = sim.day_frac()
	var phase := tr("Night") if sim.night_amt > 0.5 and sim.nat.eclipse_t < 0 else (tr("Dusk") if f > 0.65 else tr("Day"))
	if sim.night_ff(): phase = "[color=#a8c8ff]%s[/color]" % tr("Night, all asleep")
	if sim.hz.on():
		phase += " · " + tr("Year %d") % sim.hz.year() + " " + tr(sim.hz.season())
		if sim.hz.weather != "clear" or sim.hz.winter(): phase += " · [color=#cfe8ff]%s[/color]" % tr(sim.hz.weather_name())
		for omen in sim.nat.status(): phase += " · [color=#ffb07a]%s[/color]" % omen
	var since: String = tr("%.0fs") % (sim.ticks_since_llm * 0.05) if sim.llm_calls > 0 else "-"
	top_stats.text = tr("[color=#ffd36b]Day %d[/color] %s · [color=#e6c890]%s[/color]\n[color=%s]Food %d/%d[/color]   [color=#d8b483]Wood %d[/color]   [color=#c8c8d0]Stone %d[/color]   [color=#c8a8ff]Lore %d[/color]   Pop %d/%d   [color=#ffb0e0]Devotion %d%%[/color]   [color=#b6f28a]Explored %d%%[/color]   [color=#9fd0ff]LLM calls: %d[/color]") % [
		sim.day(), phase, tr(D.ERA_NAMES[sim.evo.era]), "#ff6b6b" if sim.stock["food"] > sim.food_cap() else "#f0a07a", sim.stock["food"], sim.food_cap(), sim.stock["wood"], sim.stock["stone"], sim.stock["lore"], sim.living().size(), sim.pop_cap(),
		sim.devotion, sim.explored_pct(), sim.llm_calls]
	top_stats.tooltip_text = tr("LLM node: %s") % llm.label() + "\n" + tr("Mood: %s (%d). Work goes %d%% faster or slower with it. Festivals, art, painted homes and treasures lift it; hunger, sickness and deaths lower it.") % [sim.folk.mood_word(), roundi(sim.folk.mood), roundi(absf(sim.folk.work_mult() - 1.0) * 100)] + "\n" + tr("Food %d of %d storage: the village holds %d, each Granary %d more. Food over the limit rots fast.") % [sim.stock["food"], sim.food_cap(), sim.FOOD_STORE_BASE, sim.FOOD_STORE_GRANARY]
	var extra: Array = [] # stocks that exist once their find is known
	var mc: String = "#b6f28a" if sim.folk.mood >= 60 else ("#ffd36b" if sim.folk.mood >= 40 else "#ff8a7a")
	extra.append("[color=%s]%s[/color]" % [mc, tr("Mood %d") % roundi(sim.folk.mood)])
	if sim.stock["goods"] > 0 or not sim.folk.treasures.is_empty(): extra.append("[color=#e6c46a]%s[/color]" % (tr("Goods %d") % sim.stock["goods"]))
	if sim.knows_find("willow") or sim.knows_find("yarrow"): extra.append("[color=#9ad88a]%s[/color]" % (tr("Herbs %d") % sim.stock["herbs"]))
	if sim.knows_find("copper"): extra.append("[color=#d9965a]%s[/color]" % (tr("Copper %d") % sim.stock["copper"]))
	if sim.knows_find("tin"): extra.append("[color=#a8b0b8]%s[/color]" % (tr("Tin %d") % sim.stock["tin"]))
	if not extra.is_empty(): top_stats.text += "   " + "   ".join(extra)
	if sim.ox_cap() > 0: # the herd: count, and a warning colour when it needs tending or feeding
		var oc: String = "#ff8a7a" if sim.ox_care < 25 or sim.ox_hunger > 0 else "#e0c89a"
		top_stats.text += "   [color=%s]%s[/color]" % [oc, tr("Oxen %d/%d") % [sim.oxen, sim.ox_cap()]]
		top_stats.tooltip_text += "\n" + tr("Oxen: %d of %d (pens). Care %d%%. Each ox eats food and lets one gatherer carry 50%% more.") % [sim.oxen, sim.ox_cap(), roundi(sim.ox_care)]
	pause_btn.text = "Resume" if sim.paused else "Pause"
	for i in speed_btns.size():
		speed_btns[i].modulate = COL_ACCENT if sim.speed == [1, 2, 4][i] else Color.WHITE

func _refresh_left() -> void:
	var sel: Array = world.selected_units()
	var single: bool = sel.size() == 1
	roster_box.visible = not single
	roster_bar.visible = not single
	for i in roster_bar.get_child_count():
		(roster_bar.get_child(i) as Button).set_pressed_no_signal(["quest", "ability"][i] == roster_mode)
	sheet_box.visible = single
	if not single:
		for c in roster_box.get_children(): c.queue_free()
		roster_buttons.clear()
		roster_headers.clear()
		roster_sig = _roster_signature()
		if roster_mode == "ability":
			_build_ability_table()
			_refresh_left_content()
			return
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
				var b := _button("", func(): _roster_click(u))
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
	var kids: Array = sim.living().filter(func(u): return not placed.has(u.id) and u.role == "child")
	for u in kids: placed[u.id] = true
	var rest: Array = sim.living().filter(func(u): return not placed.has(u.id))
	if not rest.is_empty():
		groups.append({"key": "village", "units": rest, "focus": D.VILLAGE, "color": COL_ACCENT})
	if not kids.is_empty():
		groups.append({"key": "children", "units": kids, "focus": D.VILLAGE, "color": Color("#ffd6f0")})
	return groups

## Click selects one person and looks at them; Shift-click adds or removes them from the selection.
func _roster_click(u) -> void:
	if Input.is_key_pressed(KEY_SHIFT):
		if u.id in world.selected: world.selected.erase(u.id)
		else: world.selected.append(u.id)
		world.selection_changed.emit()
	else:
		world.select_only(u)
		world.focus_on(u.pos)

func _sort_value(u, key: String) -> float:
	if key == "lv": return sim.unit_level(u)
	return u.lv(key) + u.skills[key]["xp"] / maxf(1.0, sim.xp_need(u.lv(key))) # progress breaks ties

func _sorted_living() -> Array:
	var list: Array = sim.living()
	list.sort_custom(func(a, b):
		if sort_key == "name": return (a.name < b.name) != sort_desc
		var va := _sort_value(a, sort_key)
		var vb := _sort_value(b, sort_key)
		if va == vb: return a.name < b.name
		return va > vb if sort_desc else va < vb)
	return list

## Ability view: a table with one column per capability; click a column to sort by it.
func _build_ability_table() -> void:
	var head := HBoxContainer.new()
	roster_box.add_child(head)
	var cols: Array = [["name", "Name", "Sort by name"]] + SORT_COLS
	for col in cols:
		var arrow := (" ▼" if sort_desc else " ▲") if col[0] == sort_key else ""
		var hb := _button(tr(col[1]) + arrow, func():
			if sort_key == col[0]: sort_desc = not sort_desc
			else:
				sort_key = col[0]
				sort_desc = col[0] != "name"
			_refresh_left(), col[2])
		hb.flat = true
		hb.focus_mode = Control.FOCUS_NONE
		hb.add_theme_font_size_override("font_size", 13)
		hb.add_theme_color_override("font_color", COL_ACCENT if col[0] == sort_key else COL_DIM)
		if col[0] == "name":
			hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			hb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		else:
			hb.custom_minimum_size = Vector2(COL_W, 0)
		head.add_child(hb)
	for u in _sorted_living():
		var b := _button("", func(): _roster_click(u))
		b.custom_minimum_size = Vector2(0, 32)
		roster_box.add_child(b)
		roster_buttons[u.id] = b
		var row := HBoxContainer.new()
		row.set_anchors_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 8
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(row)
		var nm := _label(_marks(u) + tr(u.name), 15, Color("#fff4d6"))
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.clip_text = true
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(nm)
		for col in SORT_COLS:
			var val: int = sim.unit_level(u) if col[0] == "lv" else u.lv(col[0])
			var c := COL_ACCENT if col[0] == sort_key else Color("#d8ccb0")
			if col[0] != "lv" and val >= 5: c = Color("#7ff0ff") # mastery unlocked
			var l := _label(str(val), 15, c)
			l.custom_minimum_size = Vector2(COL_W, 0)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(l)
	roster_box.add_child(_label(tr("★ Vice-Chieftain   ⚑ on a Task Contract   ◎ scouting · hover a row for details"), 12, COL_DIM))

## Status marks shown before a name in the ability table: ★ Vice-Chieftain, ⚑ on a Task
## Contract, ◎ scouting.
func _marks(u) -> String:
	var s := ""
	if tr(u.title) != "": s += "★"
	if u.role == "contract": s += "⚑"
	elif u.job.get("type", "") == "explore": s += "◎"
	return s + " " if s != "" else ""

## What the marks mean for this person, for the row's tooltip.
func _marks_tip(u) -> String:
	var lines: Array = []
	if tr(u.title) != "": lines.append(tr("★ Vice-Chieftain: %s") % tr(u.title))
	if u.role == "contract":
		var c = sim.contracts.by_id(u.contract_id)
		lines.append(tr("⚑ On the Task Contract '%s'") % c.plan["plan_id"] if c else tr("⚑ On a Task Contract"))
	elif u.job.get("type", "") == "explore": lines.append(tr("◎ Scouting the unknown"))
	return "\n" + "\n".join(lines) if not lines.is_empty() else ""

func _roster_signature() -> String:
	if roster_mode == "ability": # rebuild when the order or any shown value changes
		var parts2: Array = [sort_key, str(sort_desc)]
		for u in _sorted_living():
			parts2.append("%d:%d%d%d%d%d:%s:%s%s" % [u.id, u.lv("forage"), u.lv("craft"), u.lv("combat"), u.lv("lore"), u.lv("trade"), u.title, u.role, u.job.get("type", "") == "explore"])
		return ",".join(parts2)
	var parts: Array = []
	for u in sim.living():
		parts.append(tr("%d:%d:%s") % [u.id, u.contract_id if u.role == "contract" else -1, ("x" if u.job.get("type", "") == "explore" else "") + ("k" if u.role == "child" else "")])
	for c in sim.contracts.list: parts.append(tr("c%d%s") % [c.id, c.status])
	return ",".join(parts)

func _group_title(key: String, units: Array) -> String:
	if key == "scouts": return tr("▸ SCOUTING THE UNKNOWN (%d)") % units.size()
	if key == "village": return tr("▸ VILLAGE (%d)") % units.size()
	if key == "children": return tr("▸ CHILDREN (%d)") % units.size()
	var c = sim.contracts.by_id(int(key.substr(1)))
	if c == null: return key
	var ld = sim.unit_by_id(c.leader_id)
	return tr("⚑ %s · %s %d%% (%d)") % [c.plan["plan_id"], tr(c.status), roundi(c.progress * 100), units.size()]

func _refresh_left_content() -> void:
	var sel: Array = world.selected_units()
	if sel.size() != 1:
		left_title.text = tr("TRIBE (%d)%s") % [sim.living().size(), tr("  · %d selected") % sel.size() if sel.size() > 1 else ""]
		if _roster_signature() != roster_sig:
			_refresh_left()
			return
		if roster_mode == "ability":
			for id in roster_buttons:
				var au = sim.unit_by_id(id)
				roster_buttons[id].modulate = COL_ACCENT if au.id in world.selected else Color.WHITE
				roster_buttons[id].tooltip_text = tr("%s · %s\nHP %d/%d · ATK %.1f · DEF %.1f\nNow: %s") % [tr(au.name), tr(D.TRAITS[au.traits[0]]["name"]), au.hp, au.max_hp, sim.unit_atk(au), sim.unit_def(au), I.act(au.act)] + _marks_tip(au)
			return
		for g in _roster_groups():
			if roster_headers.has(g["key"]): roster_headers[g["key"]].text = _group_title(g["key"], g["units"])
		for id in roster_buttons:
			var u = sim.unit_by_id(id)
			var tag: String = " ★" + tr(u.title) if tr(u.title) != "" else ""
			var c = sim.contracts.by_id(u.contract_id) if u.role == "contract" else null
			if c and c.leader_id == u.id: tag += tr(" [leader]")
			roster_buttons[id].text = tr("   %s Lv%d%s — %s") % [tr(u.name), sim.unit_level(u), tag, I.act(u.act)]
			roster_buttons[id].modulate = COL_ACCENT if u.id in world.selected else Color.WHITE
		return
	var u = sel[0]
	left_title.text = "CHARACTER SHEET"
	var trs: Array = []
	for t in u.traits: trs.append(tr(D.TRAITS[t]["name"]))
	var s := tr("[font_size=20][color=#ffd36b]%s[/color][/font_size]  [color=#b8a888]%s[/color]\n") % [tr(u.name), tr(u.epithet)]
	if tr(u.title) != "": s += tr("[color=#9fd0ff]★ Vice-Chieftain: %s[/color]\n") % tr(u.title)
	if u.hero: s += tr("[color=#ffd36b]Mythic bloodline[/color]\n")
	s += tr("[color=#e6b8ff]%s[/color] · Level %d\n") % [", ".join(trs), sim.unit_level(u)]
	s += tr("HP %d/%d   Hunger %d%%\nATK %.1f   DEF %.1f   SPD %.2f   Kills %d\n") % [u.hp, u.max_hp, u.hunger, sim.unit_atk(u), sim.unit_def(u), u.spd, u.kills]
	s += tr("[color=#b8a888]Now:[/color] %s\n") % I.act(u.act)
	var knows: Array = sim.evo.known_by(u).map(func(id): return tr(sim.evo.tech_def(id)["name"]))
	s += tr("[color=#b8a888]Knows:[/color] %s\n\n") % (", ".join(knows) if not knows.is_empty() else tr("[color=#8a7a60]only the old ways[/color]"))
	s += tr("[color=#ffd36b]SPECIALIZATIONS[/color]\n")
	for k in D.SKILLS:
		var sk: Dictionary = u.skills[k]
		var need: float = sim.xp_need(sk["lv"])
		var bars := int(10.0 * sk["xp"] / need) if sk["lv"] < 10 else 10
		var unlock: String = (tr(" [color=#7ff0ff][%s][/color]") % tr(D.SKILL_UNLOCKS[k])) if sk["lv"] >= 5 else ""
		s += tr("%s  Lv.%d%s\n[bgcolor=#6fb04f]%s[/bgcolor][bgcolor=#3a3226]%s[/bgcolor] [color=#8a7a60]%d/%d xp[/color]\n") % [tr(D.SKILL_NAMES[k]), sk["lv"], unlock, " ".repeat(bars * 3), " ".repeat((10 - bars) * 3), sk["xp"], need]
	s += tr("\n[color=#ffd36b]MEMORY ARCHIVE[/color] [color=#8a7a60](10 most impactful)[/color]\n")
	var mem: Array = u.memory.duplicate()
	mem.sort_custom(func(a, b): return a["day"] > b["day"])
	for m in mem:
		var when: String = (tr("Day %d") % m["day"]) if m["day"] > 0 else tr("Long ago")
		s += tr("[color=#8a7a60]%s ·%s[/color] %s\n") % [when, "◆".repeat(clampi(int(m["impact"] / 3), 1, 3)), _cap(tr(m["text"]))]
	sheet_text.text = s
	var on_contract: bool = u.role == "contract"
	var child: bool = u.role == "child"
	if child: sheet_text.text = (tr("[color=#ffd6f0]A child of the tribe: plays, watches and learns. Comes of age in %d days.[/color]\n") % sim.folk.days_to_grow(u)) + sheet_text.text
	sheet_contract_btn.disabled = on_contract or child or not D.home_side(u.pos)
	sheet_contract_btn.text = tr("On contract — executing blueprint") if on_contract else tr("Assign Task Contract…")
	sheet_scout_btn.disabled = on_contract or child
	sheet_research_btn.disabled = on_contract or child or sim.evo.candidates().is_empty() or not D.home_side(u.pos)
	sheet_envoy_btn.disabled = u.role != ""
	sheet_war_btn.disabled = u.role != "" or not D.home_side(u.pos) or not sim.rivals.clans.values().any(func(c): return c["met"])
	sheet_envoy_btn.text = tr("Envoy — on a mission") if u.role == "envoy" else tr("Send as envoy…")
	sheet_research_btn.text = tr("Seek new wisdom…") if not sim.evo.candidates().is_empty() else tr("No new wisdom within reach")
	sheet_scout_btn.text = tr("Scouting… (right-click to recall)") if u.job.get("type", "") == "explore" else tr("Scout the unknown (X)")
	_vice_button(sheet_steward_btn, u, "steward")
	_vice_button(sheet_chief_btn, u, "warchief")

func _cap(s: String) -> String:
	return s.substr(0, 1).to_upper() + s.substr(1) if s.length() > 0 else s

func _refresh_right() -> void:
	for k in build_btns:
		var sd: Dictionary = D.STRUCTURES[k]
		var locked: bool = sd.has("tech") and not sim.has_tech(sd["tech"])
		var short := _shortfall(sd["wood"], sd.get("stone", 0))
		var why := ""
		if locked: why = tr("Requires %s") % tr(sim.evo.tech_def(sd["tech"])["name"])
		elif short != "": why = tr("Short of %s") % short
		var bb: Button = build_btns[k]
		bb.text = "%s\n%s" % [tr(sd["name"]), why if why != "" else _cost_long(sd)]
		bb.disabled = why != ""
		bb.tooltip_text = (why + "\n" if why != "" else "") + tr("Costs %s") % _cost_long(sd) + "\n" + tr(sd.get("desc", ""))
	var old: Array = sim.outdated()
	reno_btn.visible = not old.is_empty()
	if not old.is_empty():
		var rc: Dictionary = sim.reno_cost(old)
		reno_btn.text = tr("Renovate %d homes in %s style (%dw%s)") % [old.size(), ["", tr("hide"), tr("mud & thatch"), tr("timber & stone")][sim.evo.era], rc["wood"], (tr(" %ds") % rc["stone"]) if rc["stone"] > 0 else ""]
		var rshort := _shortfall(rc["wood"], rc["stone"])
		reno_btn.disabled = rshort != ""
		if rshort != "": reno_btn.text += "\n" + tr("Short of %s") % rshort
	var s := ""
	if sim.contracts.list.is_empty():
		s = tr("[color=#8a7a60]None yet. Select a tribesperson and press 'Assign Task Contract'.[/color]")
	for c in sim.contracts.list:
		var ld = sim.unit_by_id(c.leader_id)
		var col: String = {"done": "#b6f28a", "abandoned": "#999999", "failed": "#999999", "interrupted": "#ff6b6b", "defending": "#ff6b6b"}.get(c.status, "#ffd36b")
		s += tr("[color=%s]■[/color] [b]%s[/b] — %s\n  %s · [color=%s]%s %d%%[/color] · step %d/%d\n") % [col, c.plan["plan_id"], tr(ld.name) if ld else "?", c.substate if c.status == "executing" else "", col, tr(c.status), roundi(c.progress * 100), mini(c.step_idx + 1, c.steps.size()), c.steps.size()]
		s += tr("  [color=#8a9aa8]LLM calls: 1 negotiation + %d awakenings[/color]\n") % c.interruptions
		for line in c.events.slice(0, 3): s += tr("  [color=#a89878]%s[/color]\n") % line
	contracts_text.text = s
	var running: int = sim.contracts.list.filter(func(c): return sim.contracts.is_running(c)).size()
	var alarm: bool = sim.contracts.list.any(func(c): return c.status in ["interrupted", "defending"])
	log_tabs.set_tab_title(1, (tr("Task Contracts (%d)") % running if running > 0 else tr("Task Contracts")) + (" ⚠" if alarm else ""))
	clans_text.text = _clans_bbcode()
	var met: Array = sim.rivals.clans.keys().filter(func(id): return sim.rivals.clans[id]["met"])
	var sig := ",".join(met) + I.lang
	if sig != clans_sig:
		clans_sig = sig
		for ch in clans_btns.get_children(): ch.queue_free()
		for id in met:
			var b := _button(tr("Envoy to %s…") % tr(sim.rivals.clans[id]["name"]), func(): open_envoy(null, id), "Choose someone to carry our words to their chieftain")
			b.add_theme_font_size_override("font_size", 13)
			clans_btns.add_child(b)
			var tb := _button(tr("Trade with %s…") % tr(sim.rivals.clans[id]["name"]), func(): open_trade(id), "Send someone with goods to trade at their village")
			tb.add_theme_font_size_override("font_size", 13)
			clans_btns.add_child(tb)
	if log_dirty:
		log_dirty = false
		var l := ""
		var colors := {"danger": "#ff8a8a", "story": "#ffd6a0", "contract": "#9fd0ff", "tech": "#c8a8ff", "vice": "#a8e0a8", "combat": "#ffb07a", "xp": "#7ff0ff", "build": "#b6f28a"}
		for e in sim.log_lines.slice(0, 40):
			l += tr("[color=#7a6a50]D%d[/color] [color=%s]%s[/color]\n") % [e["day"], colors.get(e["kind"], "#d8ccb0"), _link_names(e)]
		log_text.text = l

## A chronicle line with the names of the people it is about turned into links (`u<id>`).
## Only the names recorded with the line are linked, so a one-character Chinese name never
## lights up inside an ordinary word.
func _link_names(e: Dictionary) -> String:
	var text: String = e["text"]
	var done := {}
	for w in e.get("who", []):
		var nm: String = w["name"]
		if nm == "" or done.has(nm): continue
		done[nm] = true
		var at := text.find(nm)
		if at < 0: continue
		text = text.substr(0, at) + "[url=u%d][color=#ffe6a8]%s[/color][/url]" % [w["id"], nm] + text.substr(at + nm.length())
	return text

## Clicking a name in the chronicle: select that person and look at them.
func _on_log_link(meta) -> void:
	var m := str(meta)
	if not m.begins_with("u"): return
	var u = sim.unit_by_id(int(m.substr(1)))
	if u == null: return
	world.focus_on(u.pos)
	if not u.dead: world.select_only(u)

func _clans_bbcode() -> String:
	var out := ""
	var cols := {"Blood feud": "#ff5a4a", "Hostile": "#ff8a6a", "Wary": "#ffe08a", "Friendly": "#b6f28a", "Trusted": "#9af0b0", "Allied": "#8af2d0", "Vassal": "#e6c46a"}
	for id in sim.rivals.clans:
		var c: Dictionary = sim.rivals.clans[id]
		if not c["met"]: continue
		var st: String = sim.rivals.stance(id)
		var marching: int = sim.predators.filter(func(p): return p.clan == id and p.kind == "warrior" and p.raid and not p.dead and not p.fled).size()
		out += tr("[color=#%s]■[/color] [b]%s[/b] · %s %s · [color=%s]%s (%+d)[/color]\n") % [c["color"].to_html(false), tr(c["name"]), tr(c["chief"]), tr(c["epithet"]), cols[st], tr(st), roundi(c["relation"])]
		var tt: String = sim.rivals.treaty_text(id)
		if tt != "": out += tr("  [color=#8af2d0]☮ %s[/color]\n") % tt
		var env = sim.unit_by_id(c["envoy"])
		if env and env.role == "envoy": out += tr("  [color=#9fd0ff]✉ %s is on the way as our envoy[/color]\n") % tr(env.name)
		if marching > 0: out += tr("  [color=#ff6b6b]⚔ %d warriors marching on us![/color]\n") % marching
	if out == "": out = tr("[color=#8a7a60]No other clans met yet. Scouts may find them beyond the fog.[/color]")
	return "[font_size=14]" + out.strip_edges() + "[/font_size]"

## Switch English <-> Chinese live. Static labels re-translate themselves; dynamic text
## is rebuilt on the next refresh. Old chronicle lines keep the language they were written in.
func _toggle_lang() -> void:
	var l := "en" if I.is_zh() else "zh"
	I.setup(l)
	I.save_pref(l)
	get_window().title = tr("Era of Savagery · Clan Chronicles")
	lang_btn.text = I.LANGS["en" if I.is_zh() else "zh"]
	roster_sig = ""
	_refresh_left()
	_refresh_right()
	_refresh_top()

func _cost_short(sd: Dictionary) -> String:
	return tr("%d") % sd["wood"] if sd.get("stone", 0) == 0 else tr("%dw %ds") % [sd["wood"], sd["stone"]]

## What we still lack to afford a cost ("" = affordable), e.g. "12 wood and 5 stone".
func _shortfall(wood: int, stone: int) -> String:
	var parts: Array = []
	if sim.stock["wood"] < wood: parts.append(tr("%d wood") % ceili(wood - sim.stock["wood"]))
	if sim.stock["stone"] < stone: parts.append(tr("%d stone") % ceili(stone - sim.stock["stone"]))
	return tr(" and ").join(parts) if parts.size() > 0 else ""

func _cost_long(sd: Dictionary) -> String:
	return tr("%d wood") % sd["wood"] + ((tr(" and %d stone") % sd["stone"]) if sd.get("stone", 0) > 0 else "")

## Vice-Chieftain buttons say why they are disabled instead of just greying out.
func _vice_button(b: Button, u, role: String) -> void:
	var why: String = sim.appoint_block(u, role)
	var steward: bool = role == "steward"
	b.disabled = why != ""
	match why:
		"already":
			b.text = tr("★ Steward") if steward else tr("★ War Chief")
			b.tooltip_text = tr("%s already holds this office") % tr(u.name)
		"child":
			b.text = tr("Appoint Steward") if steward else tr("Appoint War Chief")
			b.tooltip_text = tr("Too young to lead")
		"no_slot":
			b.text = tr("Steward (no slot)") if steward else tr("War Chief (no slot)")
			b.tooltip_text = tr("All %d Vice-Chieftain slots are taken. Tribal Code and the Council of Elders tradition each add one.") % sim.vice_slots()
		_:
			b.text = tr("Appoint Steward") if steward else tr("Appoint War Chief")
			b.tooltip_text = tr("Tier 3: auto-manages idle villagers") if steward else tr("Tier 3: rallies warriors vs. beasts near the village")

func _appoint(role: String) -> void:
	var sel: Array = world.selected_units()
	if sel.size() != 1: return
	if not sim.appoint(sel[0], role):
		sim.popup(sel[0].pos, tr("No Vice-Chieftain slot free (Tribal Code or the Council of Elders adds one)"), Color("#ff8080"))
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
	# Content taller than the window scrolls instead of running off the screen.
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	p.add_child(sc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)
	var fit := func():
		if not is_instance_valid(sc): return
		var need: Vector2 = v.get_combined_minimum_size()
		sc.custom_minimum_size = Vector2(maxf(width - 24.0, need.x), minf(need.y, get_viewport().get_visible_rect().size.y - 80.0))
	v.minimum_size_changed.connect(fit)
	fit.call()
	v.add_child(_label(title, 22, Color("#ff8a7a") if danger else COL_ACCENT))
	return v

func _close_modal() -> void:
	if modal:
		modal.queue_free()
		modal = null

func _show_intro() -> void:
	var v := _open_modal(tr("Era of Savagery · Clan Chronicles"))
	var r := _rich(0, true)
	r.text = tr("""You are the [color=#ffd36b]Great Chieftain[/color]. You lead your tribe on three levels of command:

[color=#ffd36b]Tier 1 · Direct micro[/color] — select tribespeople (click / drag) and right-click trees, bushes, deer, tigers, construction sites or ground.
[color=#ffd36b]Tier 2 · Task Contracts[/color] — select one person (try [b]%s[/b], [b]%s[/b] or [b]%s[/b]) and press [i]Assign Task Contract[/i]. Their LLM persona negotiates a blueprint for a settlement on the frontier. Once sealed, a deterministic state machine executes it with [b]zero LLM calls[/b] (watch the counter in the top bar) — until an ambush re-awakens the leader.
[color=#ffd36b]Tier 3 · Vice-Chieftains[/color] — appoint a Steward to auto-manage idle villagers.
[color=#ffd36b]Exploration[/color] — the land beyond the firelight is hidden. Select someone and press [b]X[/b] (or [i]Scout the unknown[/i]) to auto-explore; landmarks reward the finder with lore, food or wood and a new memory. Beware the saber-tooth dens. The minimap (bottom left) shows what you know: click it to look, right-click it to send the selected people.

[color=#ffd36b]Evolution[/color] — new wisdom comes from [i]practice[/i] (chopping wood teaches stone tools, rituals lead to totems) or from lore and research contracts. Each age changes homes, gear and what people can do; the tribe's culture drifts with its deeds and adopts traditions. Knowledge lives in people until it is carved into totems or laws.
Every task grants specialization XP and notable events enter each person's [b]Memory Archive[/b], which is fed back into their next negotiation. Research the Wisdom Tree with lore from rituals. Milestone events: Overpopulation (%d people), Birth of the Chosen One (100%% devotion).

LLM node: [color=#9fd0ff]%s[/color]. Open [i]LLM Settings[/i] to use DeepSeek or GLM with your API key.""") % (_intro_names() + [int(sim.RULES["triggers"]["overpop"]["pop"]), llm.label()])
	var brief: String = D.MAP.get("brief", "")
	if brief != "": r.text = "[color=#ffd36b]%s[/color] — %s\n\n" % [tr(D.MAP.get("name", "")), tr(brief)] + r.text
	v.add_child(r)
	v.add_child(_button("Begin", _close_modal))

## Who to try first as contract leaders: the best builder, fighter and mystic.
func _intro_names() -> Array:
	var out: Array = []
	for sk in ["craft", "combat", "lore"]:
		var best = null
		for u in sim.living():
			if u.role == "child" or tr(u.name) in out: continue
			if best == null or u.lv(sk) > best.lv(sk): best = u
		out.append(tr(best.name) if best else "?")
	return out

# ------------------------------------------------------------ Phase 1: negotiation
var neg := {}

func _start_contract_for_selected() -> void:
	var sel: Array = world.selected_units()
	if sel.size() == 1: open_negotiation(sel[0])

func open_negotiation(leader, kind := "settle") -> void:
	var trs: Array = []
	for t in leader.traits: trs.append(tr(D.TRAITS[t]["name"]))
	var research: bool = kind == "research"
	var war: bool = kind == "war"
	var v := _open_modal((tr("RESEARCH CONTRACT · Seeking new wisdom with %s") if research else (tr("WAR CONTRACT · Planning the raid with %s") if war else tr("TASK CONTRACT · Phase 1: Negotiation with %s"))) % tr(leader.name), 1080)
	var token := modal_token
	var max_crew := mini(4 if research else (6 if war else 5), sim.contracts.available_helpers(leader.id).size() + 1)
	neg = {"leader": leader, "kind": kind, "history": [], "bp": {}, "raw": {}, "terms_set": false, "syncing": false, "busy": false, "calls": 0, "token": token}
	v.add_child(_label(tr("%s \"%s\" · %s · Lv%d · Craft %d / Combat %d / Lore %d · HP %d/%d") % [tr(leader.name), tr(leader.epithet), ", ".join(trs), sim.unit_level(leader), leader.lv("craft"), leader.lv("combat"), leader.lv("lore"), leader.hp, leader.max_hp], 14, Color("#e6b8ff")))
	var dh := HBoxContainer.new()
	v.add_child(dh)
	dh.add_child(_label("Directive:", 15, COL_DIM))
	var directive := LineEdit.new()
	directive.text = tr("Find new wisdom for the tribe") if research else (tr("Raid a neighbouring clan") if war else tr("Found a new settlement on the frontier"))
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
	reply.placeholder_text = (tr("Reply to %s… (e.g. 'seek farming instead', 'be quick about it')") if research else (tr("Reply to %s… (e.g. 'burn their huts', 'scout first', 'take their food')") if war else tr("Reply to %s… (e.g. 'make it bigger', 'skip the wall', 'focus on fishing')"))) % tr(leader.name)
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
	if war:
		g.add_child(_label("Enemy", 14, COL_DIM))
		var tgt := OptionButton.new()
		var ids: Array = []
		for id in sim.rivals.clans:
			if not sim.rivals.clans[id]["met"]: continue
			tgt.add_item(tr("%s (%s)") % [tr(sim.rivals.clans[id]["name"]), tr(sim.rivals.stance(id))])
			ids.append(id)
		g.add_child(tgt)
		neg["target"] = tgt
		neg["target_ids"] = ids
		tgt.item_selected.connect(mark)
		g.add_child(_label("Objective", 14, COL_DIM))
		var obj := OptionButton.new()
		for o in sim.contracts.WAR_OBJECTIVES: obj.add_item(tr({"loot": "Plunder their stores", "burn": "Burn their huts", "break": "Break their warriors"}[o]))
		g.add_child(obj)
		neg["objective"] = obj
		obj.item_selected.connect(mark)
	elif research:
		g.add_child(_label("Wisdom to seek", 14, COL_DIM))
		var tech := OptionButton.new()
		tech.add_item(tr("Let %s choose") % tr(leader.name))
		var ids: Array = [""]
		for id in sim.evo.candidates():
			tech.add_item(tr("%s (%d%% understood)") % [tr(sim.evo.tech_def(id)["name"]), roundi(sim.evo.insight_frac(id) * 100)])
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
	rcol.add_child(_button(tr("Ask %s to revise with these terms") % tr(leader.name), func(): _neg_request("")))
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
	if neg.get("kind", "settle") == "war":
		return {"kind": "war", "crew_size": int(neg["crew"].value), "target": neg["target_ids"][maxi(0, neg["target"].selected)] if not neg["target_ids"].is_empty() else "",
			"objective": sim.contracts.WAR_OBJECTIVES[maxi(0, neg["objective"].selected)]}
	if neg.get("kind", "settle") == "research":
		return {"kind": "research", "crew_size": int(neg["crew"].value), "tech": neg["tech_ids"][neg["tech"].selected]}
	return {"crew_size": int(neg["crew"].value), "capacity_target": int(neg["cap"].value), "focus": neg["focus"].get_item_text(neg["focus"].selected)}

func _neg_send() -> void:
	var msg: String = neg["reply"].text.strip_edges()
	if msg == "" or neg["busy"]: return
	neg["reply"].text = ""
	neg["history"].append({"speaker": "Chieftain", "text": msg})
	neg["chat"].append_text(tr("\n[color=#ffd36b][b]You:[/b][/color] %s\n") % msg)
	_neg_request(msg)

func _neg_request(msg: String) -> void:
	if neg["busy"]: return
	neg["busy"] = true
	var token: int = neg["token"]
	var leader = neg["leader"]
	neg["confirm"].disabled = true
	neg["status"].text = tr("Awakening %s's LLM persona core (%s)…") % [tr(leader.name), llm.label()]
	neg["chat"].append_text(tr("[color=#8a7a60][i]%s is thinking…[/i][/color]\n") % tr(leader.name))
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
		note = tr(" · blueprint invalid, engine substituted a safe plan")
	if not san["ok"]:
		neg["chat"].append_text(tr("[color=#ff8a7a][i]%s[/i][/color]\n") % " ".join(san["notes"]))
		neg["status"].text = "No valid plan is possible right now."
		neg["busy"] = false
		return
	neg["raw"] = r["blueprint"] if r["blueprint"] is Dictionary else san["blueprint"]
	neg["bp"] = san["blueprint"]
	neg["history"].append({"speaker": tr(leader.name), "text": r["speech"]})
	neg["chat"].append_text(tr("[color=#e6b8ff][b]%s:[/b][/color] %s\n") % [tr(leader.name), r["speech"]])
	if r.get("error", "") != "":
		neg["chat"].append_text(tr("[color=#ff8a7a][i](cloud LLM failed: %s — used offline persona)[/i][/color]\n") % r["error"])
	_neg_sync_terms(san["blueprint"])
	_neg_show_bp(san)
	neg["status"].text = tr("LLM node: %s · %d call(s) this negotiation%s. Adjust terms or reply, then seal.") % [r.get("source", "?"), neg["calls"], note]
	neg["confirm"].disabled = false
	neg["busy"] = false

func _neg_sync_terms(bp: Dictionary) -> void:
	neg["syncing"] = true
	neg["crew"].value = bp["crew_size"]
	if neg.get("kind", "settle") == "war":
		var ti: int = neg["target_ids"].find(bp.get("target", ""))
		if ti >= 0: neg["target"].select(ti)
		neg["objective"].select(sim.contracts.WAR_OBJECTIVES.find(bp.get("objective", "loot")))
	elif neg.get("kind", "settle") == "research":
		var i: int = neg["tech_ids"].find(bp.get("tech", ""))
		if i > 0: neg["tech"].select(i)
	else:
		neg["cap"].value = bp["capacity_target"]
		neg["focus"].select(D.FOCUSES.find(bp["focus"]))
	neg["syncing"] = false

func _neg_show_bp(san: Dictionary) -> void:
	neg["san"] = san
	var bp: Dictionary = san["blueprint"]
	var s := tr("[color=#ffd36b]%s[/color] · crew %d · houses %d (target %d) · wood ≈ %d\n") % [bp["plan_id"], bp["crew_size"], sim.contracts.housing(bp), bp["capacity_target"], sim.contracts.wood_needed(bp)]
	if bp.get("kind", "settle") == "war":
		var rc: Dictionary = sim.rivals.clans[bp["target"]]
		s = tr("[color=#ffd36b]%s[/color] · against [color=#ff9b7a]%s[/color] (%s) · crew %d\n[color=#b8a888]Goal: %s[/color]\n") % [bp["plan_id"], tr(rc["name"]), tr(sim.rivals.stance(bp["target"])), bp["crew_size"], tr(sim.contracts.WAR_OBJECTIVE_TEXT[bp["objective"]])]
	elif bp.get("kind", "settle") == "research":
		var td: Dictionary = sim.evo.tech_def(bp["tech"])
		s = tr("[color=#ffd36b]%s[/color] · seeking [color=#c8a8ff]%s[/color] (%d%% understood) · crew %d\n[color=#b8a888]%s[/color]\n") % [bp["plan_id"], tr(td["name"]), roundi(sim.evo.insight_frac(bp["tech"]) * 100), bp["crew_size"], tr(td["desc"])]
	var i := 1
	for st in bp["steps"]:
		s += tr(" %d. %s\n") % [i, sim.contracts.step_text(st)]
		i += 1
	s += tr("[color=#ff9b7a]abort on:[/color] %s\n") % ", ".join(bp["abort_conditions"].map(func(a): return _abort_text(a)))
	for n in san["notes"]: s += tr("[color=#ff8a7a]⚠ %s[/color]\n") % n
	if neg.get("show_json", false): s += tr("\n[color=#7a8a98][code]%s[/code][/color]") % JSON.stringify(bp, "  ")
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
	var v := _open_modal(tr("⚠ EMERGENCY AWAKENING · %s") % c.plan["plan_id"], 900, true)
	var token := modal_token
	world.focus_on(c.site)
	var info := _rich(0, true)
	info.text = tr("[color=#ff9b7a]Abort condition:[/color] %s   [color=#b8a888]Progress:[/color] %d%%   [color=#b8a888]Threat:[/color] %s\n[color=#b8a888]Built:[/color] %s   [color=#b8a888]Half-built:[/color] %s\n[color=#b8a888]Crew:[/color] %s") % [
		tr(sm["reason"]), sm["progress_pct"], sm["threat"], ", ".join(sm["built"]) if not sm["built"].is_empty() else "—",
		", ".join(sm["half_built"]) if not sm["half_built"].is_empty() else "—", ", ".join(sm["crew"])]
	v.add_child(info)
	var speech := _rich(0, true)
	speech.text = tr("[color=#8a7a60][i]The state machine has halted. Re-awakening %s's LLM node…[/i][/color]") % tr(ld.name)
	v.add_child(speech)
	var opts := VBoxContainer.new()
	v.add_child(opts)
	var r: Dictionary = await llm.emergency(sim.contracts.emergency_ctx(c))
	if modal == null or modal_token != token: return
	speech.text = tr("[color=#e6b8ff][b]%s:[/b][/color] %s\n[color=#8a9aa8](%s)%s[/color]") % [tr(ld.name), r["speech"], r.get("source", ""), (tr(" — cloud error: ") + r["error"]) if r.get("error", "") != "" else ""]
	for o in r["options"]:
		var eff: String = o["effect"]
		var b := _button(tr("%s   [%s]") % [tr(o["label"]), tr(sim.contracts.EFFECTS.get(eff, eff))], func():
			sim.contracts.resolve(c, eff, tr(o["label"]))
			_close_modal()
			sim.paused = false)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		opts.add_child(b)

func _toast_contract_done(c) -> void:
	if modal: return
	var v := _open_modal(tr("Task Contract Complete · %s") % c.plan["plan_id"], 700)
	var ld = sim.unit_by_id(c.leader_id)
	var r := _rich(0, true)
	var who: String = tr(ld.name) if ld else tr("The tribe")
	if c.kind == "war":
		r.text = tr("%s's war party is home from the %s: %s.") % [who, tr(sim.rivals.clans[c.plan["target"]]["name"]), c.flags.get("spoils", "")]
	elif c.kind == "research":
		r.text = tr("%s's crew has finished its experiments: the tribe now knows %s.") % [who, tr(sim.evo.tech_def(c.plan["tech"])["name"])]
	else:
		r.text = tr("%s's crew has finished every step of the blueprint. The outpost now houses up to %d more tribespeople.") % [who, sim.contracts.housing(c.plan)]
	v.add_child(r)
	var was_paused: bool = sim.paused
	sim.paused = true
	v.add_child(_button("Continue", func(): _close_modal(); sim.paused = was_paused))

# ------------------------------------------------------------ milestone events
func _on_event(id: String) -> void:
	if sim.legacy.owns_event(id):
		_show_ending(id)
		return
	var d: Dictionary = sim.event_def(id)
	var v := _open_modal("☼ " + d["title"], 820)
	var txt := _rich(0, true)
	txt.text = tr("[i]%s[/i]") % d["text"]
	v.add_child(txt)
	var i := 0
	for o in d["options"]:
		var idx := i
		var b := _button(tr("%s — %s") % [tr(o["label"]), o["desc"]], func(): _event_choose(id, idx))
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
			var trs: String = tr(D.TRAITS[u.traits[0]]["name"])
			v.add_child(_button(tr("%s \"%s\" — %s, Lv%d") % [tr(u.name), tr(u.epithet), trs, sim.unit_level(u)], func(): open_negotiation(u)))
	if r.get("open_war", "") != "":
		var foe: String = r["open_war"]
		v.add_child(_label("Choose who leads the war party:", 15, COL_DIM))
		var fighters: Array = sim.contracts.available_helpers()
		fighters.sort_custom(func(a, b): return a.lv("combat") > b.lv("combat"))
		for u in fighters.slice(0, 5):
			var who = u
			v.add_child(_button(tr("%s \"%s\" — Combat %d") % [tr(u.name), tr(u.epithet), u.lv("combat")], func():
				open_negotiation(who, "war")
				var ti: int = neg["target_ids"].find(foe)
				if ti >= 0: neg["target"].select(ti)))
	v.add_child(_button("Continue", func(): _close_modal(); sim.paused = false))

# ------------------------------------------------------------ tech tree
func _open_tech() -> void:
	var v := _open_modal(tr("WISDOM & CULTURE · %s · Lore: %d") % [tr(D.ERA_NAMES[sim.evo.era]), sim.stock["lore"]], 1240)
	var was_paused: bool = sim.paused
	sim.paused = true
	var note := tr("Knowledge is [color=#b6f28a]codified[/color] - it can no longer be lost.") if sim.evo.codified else \
		(tr("Knowledge is [color=#ff9b7a]oral[/color]: a tech dies with its last keeper. Megalithic Totems or a Tribal Code would preserve it.") if sim.evo.oral_tradition else tr("Oral tradition is off."))
	var hint := _rich(0, true)
	hint.text = tr("New wisdom grows from [i]practice[/i] (the bar fills as people do related work) and can be finished with lore or a research contract. ") + note
	v.add_child(hint)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	v.add_child(h)
	for era in [1, 2, 3]:
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(col)
		col.add_child(_header(tr(D.ERA_NAMES[era]).to_upper()))
		for tdef in D.TECHS:
			if tdef["era"] != era: continue
			col.add_child(_tech_card(tdef, was_paused))
	v.add_child(_header(tr("CULTURE · %s") % sim.evo.culture_summary().capitalize()))
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
		at += tr("%s %s %s  [color=#8a7a60](%+d)[/color]\n") % [_pad(tr(D.CULTURE_AXES[a][1]), 9), bar, _pad(tr(D.CULTURE_AXES[a][0]), 9), roundi(val)]
	axes.text = "[font_size=14]" + at + "[/font_size][color=#8a7a60]" + tr("Values drift with deeds: hunting and scouting make the tribe roam, fields settle it; kills harden it, rituals turn it to the spirits, Vice-Chieftains rank it, shared meals bind it.") + "[/color]"
	cg.add_child(axes)
	var trads := _rich(0, true)
	trads.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tt := tr("[color=#ffd36b]TRADITIONS[/color] [color=#8a7a60](adopted at ±%d)[/color]\n") % D.TRADITION_THRESHOLD
	for t in D.TRADITIONS:
		var pole: String = tr(D.CULTURE_AXES[t["axis"]][0 if t["sign"] > 0 else 1])
		if sim.evo.has_trad(t["id"]):
			tt += tr("[color=#b6f28a]✔ %s[/color] (Day %d) - %s\n") % [tr(t["name"]), sim.evo.traditions[t["id"]], tr(t["desc"])]
		else:
			tt += tr("[color=#6a5a48]○ %s - needs %s[/color]\n") % [tr(t["name"]), pole]
	trads.text = tt
	cg.add_child(trads)
	if not sim.folk.treasures.is_empty():
		v.add_child(_header(tr("TREASURES OF THE TRIBE · %d") % sim.folk.treasures.size()))
		var tt2 := _rich(0, true)
		tt2.text = "\n".join(sim.folk.treasures.map(func(t): return tr("[color=#e6c46a]✦ The %s[/color], made by %s on Day %d") % [tr(t["name"]), tr(t["maker"]), t["day"]]))
		v.add_child(tt2)
	v.add_child(_header(tr("DISCOVERIES · %d / %d") % [sim.known_finds.size(), D.FINDS.size()]))
	var fg := HBoxContainer.new()
	fg.add_theme_constant_override("separation", 16)
	v.add_child(fg)
	for g in D.FIND_GROUPS:
		var col := _rich(0, true)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var ft := "[color=#ffd36b]%s[/color]\n" % tr(D.FIND_GROUPS[g]).to_upper()
		for id in D.FINDS:
			var fd: Dictionary = D.FINDS[id]
			if fd["group"] != g: continue
			if sim.knows_find(id):
				ft += tr("[color=#b6f28a]✔ %s[/color] (Day %d) - [font_size=13]%s[/font_size]\n") % [tr(fd["name"]), sim.known_finds[id], tr(fd["desc"])]
			else:
				ft += "[color=#6a5a48]○ ???[/color]\n"
		col.text = ft
		fg.add_child(col)
	v.add_child(_button("Close", func(): _close_modal(); sim.paused = was_paused))

## The burial ground: everyone laid to rest there, how they fell, and what they are remembered for.
func open_graves(s) -> void:
	var v := _open_modal(tr("BURIAL GROUND · %d laid to rest") % s.graves.size(), 760)
	var was_paused: bool = sim.paused
	sim.paused = true
	var body := _rich(0, true)
	var t := ""
	if s.graves.is_empty(): t = tr("[color=#8a7a60]No one rests here yet.[/color]")
	var graves: Array = s.graves.duplicate()
	graves.reverse() # the most recent first
	for g in graves:
		var u = sim.unit_by_id(g.get("id", -1))
		var nm: String = tr(g["name"])
		if u and u.epithet != "": nm += " [color=#a89878]\"%s\"[/color]" % tr(u.epithet)
		t += "[color=#ffd36b]✝ %s[/color]\n" % nm
		if u:
			t += tr("Fell on Day %d: %s.") % [int(u.fell_t / D.DAY_LEN) + 1, u.death_cause if u.death_cause != "" else tr("lost to hunger and cold")] + " "
		t += (tr("The body was never found; a stone keeps the name (Day %d).") % g["day"]) if g["lost"] else (tr("Laid to rest on Day %d.") % g["day"])
		if u:
			var best: Dictionary = {}
			var witnessed: String = tr("witnessed %s %s on Day %d").split("%s")[0] # someone else's death is no epitaph
			for m in u.memory:
				if m["day"] > 0 and not m["text"].begins_with(witnessed) and (best.is_empty() or m["impact"] > best["impact"]): best = m
			if not best.is_empty(): t += "\n[color=#a89878][i]" + tr("Remembered: %s") % tr(best["text"]) + "[/i][/color]"
		t += "\n\n"
	body.text = t
	v.add_child(body)
	v.add_child(_button("Close", func(): _close_modal(); sim.paused = was_paused))

func _abort_text(a: String) -> String:
	if a.begins_with("hp_below_"): return tr("leader HP below %s") % a.trim_prefix("hp_below_")
	return tr(a)

func _pad(s2: String, n: int) -> String:
	return s2 + " ".repeat(maxi(0, n - s2.length()))

func _tech_card(tdef: Dictionary, was_paused: bool) -> Control:
	var id: String = tdef["id"]
	var known: bool = sim.has_tech(id)
	var reachable: bool = sim.evo.prereqs_met(id)
	var p := PanelContainer.new()
	var pv := VBoxContainer.new()
	p.add_child(pv)
	pv.add_child(_label(tr(tdef["name"]), 16, Color("#b6f28a") if known else (COL_ACCENT if reachable else Color("#8a7a60"))))
	pv.add_child(_label(tr(tdef["desc"]), 13, COL_DIM))
	var info := _rich(0, true)
	var how: Array = []
	for k in tdef["practice"]: how.append(tr(D.PRACTICE_NAMES[k]))
	if known:
		var keepers: int = sim.evo.keepers(id).size()
		var by: String = (tr(" · invented by %s") % tr(sim.evo.inventors[id])) if sim.evo.inventors.has(id) else ((tr(" · taught by %s") % tr(sim.evo.teachers[id])) if sim.evo.teachers.has(id) else "")
		info.text = tr("[color=#b6f28a]Known[/color]%s · %d keeper%s") % [by, keepers, "" if keepers == 1 else I.plural_s()]
	else:
		var frac: float = sim.evo.insight_frac(id)
		var bars := int(frac * 14)
		info.text = tr("[bgcolor=#8a6ad0]%s[/bgcolor][bgcolor=#3a3226]%s[/bgcolor] %d%% understood\n[color=#8a7a60]Learned by %s[/color]") % [" ".repeat(bars * 2), " ".repeat((14 - bars) * 2), roundi(frac * 100), ", ".join(how)]
		if not reachable:
			var names: Array = []
			for rq in tdef["req"]:
				if not sim.has_tech(rq): names.append(tr(sim.evo.tech_def(rq)["name"]))
			for f in tdef.get("finds", []):
				if not sim.knows_find(f): names.append(tr("finding %s") % tr(D.FINDS[f]["name"]))
			info.text += tr("\n[color=#8a7a60]Requires %s[/color]") % ", ".join(names)
	pv.add_child(info)
	if not known:
		var cost: int = sim.evo.lore_cost(id)
		var b := _button(tr("Teach now (%d lore)") % cost, func():
			var err: String = sim.research(id)
			if err == "":
				_close_modal()
				sim.paused = was_paused
				_open_tech()
			else: sim.popup(D.VILLAGE, tr(err), Color("#ff8080")))
		b.disabled = not reachable or sim.stock["lore"] < cost
		pv.add_child(b)
	return p

# ------------------------------------------------------------ settings
const SaveGame = preload("res://scripts/save_game.gd")

## The save slots: numbered ones to save into, the quick save and the autosaves to load.
func open_saves() -> void:
	if game == null: return
	var was_paused: bool = sim.paused
	var v := _open_modal("SAVE / LOAD", 760)
	var cfg: Dictionary = game.SAVE_CFG
	var heads := {}
	for h in SaveGame.slots(): heads[h["slot"]] = h
	var names: Array = []
	for i in int(cfg.get("slots", 6)): names.append("slot%d" % (i + 1))
	names.append(str(cfg.get("quick_slot", "quicksave")))
	for i in int(cfg.get("autosave_keep", 3)): names.append("autosave%d" % (i + 1))
	var block: String = game.save_block()
	if block != "": v.add_child(_label(block, 14, Color("#ffb07a")))
	var g := GridContainer.new()
	g.columns = 4
	g.add_theme_constant_override("h_separation", 12)
	v.add_child(g)
	for slot in names:
		var h: Dictionary = heads.get(slot, {})
		var title: String = tr("Autosave %s") % slot.trim_prefix("autosave") if slot.begins_with("autosave") else (tr("Quick save") if slot == cfg.get("quick_slot", "quicksave") else tr("Slot %s") % slot.trim_prefix("slot"))
		g.add_child(_label(title, 15, COL_ACCENT))
		g.add_child(_label(tr("Day %d · %d people · %s") % [int(h["day"]), int(h["pop"]), str(h["saved"])] if not h.is_empty() else tr("(empty)"), 14, COL_TEXT if not h.is_empty() else COL_DIM))
		var sb := _button("Save", func():
			var err: String = game.save_to(slot)
			toast(tr("Saved to %s") % title if err == "" else tr(err))
			if err == "": open_saves())
		sb.disabled = block != "" or slot.begins_with("autosave")
		g.add_child(sb)
		var lb := _button("Load", func():
			var err: String = game.load_from(slot)
			if err != "": toast(tr(err)))
		lb.disabled = h.is_empty()
		g.add_child(lb)
	var auto := CheckBox.new()
	auto.text = tr("Autosave")
	auto.button_pressed = game.autosave_on()
	auto.toggled.connect(func(b):
		var cf := ConfigFile.new()
		cf.load(SETTINGS_CFG)
		cf.set_value("save", "autosave", b)
		cf.save(SETTINGS_CFG))
	v.add_child(auto)
	v.add_child(_button("Close", func(): _close_modal(); sim.paused = was_paused))

func _open_sound() -> void:
	if audio == null: return
	var v := _open_modal("SOUND", 520)
	var was_paused: bool = sim.paused
	var g := GridContainer.new()
	g.columns = 2
	v.add_child(g)
	for k in [["master", "Volume"], ["music", "Music"], ["sfx", "Sound effects"], ["ambience", "Sounds of the land"]]:
		g.add_child(_label(k[1], 15, COL_DIM))
		var sl := HSlider.new()
		sl.min_value = 0.0
		sl.max_value = 1.0
		sl.step = 0.05
		sl.value = float(audio.vol.get(k[0], 0.7))
		sl.custom_minimum_size = Vector2(300, 0)
		sl.value_changed.connect(func(x): audio.set_volume(k[0], x))
		g.add_child(sl)
	v.add_child(_button("Close", func(): _close_modal(); sim.paused = was_paused))

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
	var hh := HBoxContainer.new()
	v.add_child(hh)
	hh.add_child(_label("Challenges", 15, COL_DIM))
	var lvl := OptionButton.new()
	for k in sim.hz.LEVELS: lvl.add_item({"off": "Off (no seasons, weather, wolves, sickness or famine)", "normal": "Normal", "harsh": "Harsh"}[k])
	lvl.select(sim.hz.LEVELS.find(sim.hz.level))
	lvl.item_selected.connect(func(i): sim.hz.level = sim.hz.LEVELS[i])
	hh.add_child(lvl)
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

# ------------------------------------------------------------ diplomacy: envoys and parley
## Pick who goes and/or to which clan (whichever isn't given).
func open_envoy(u, clan_id: String) -> void:
	var v := _open_modal(tr("SEND AN ENVOY"), 720)
	var R = sim.rivals
	if u == null:
		var c: Dictionary = R.clans[clan_id]
		v.add_child(_label(tr("Who will carry our words to %s %s of the %s? Lore makes a persuasive speaker; martial clans respect warriors; the devout are welcome among the Heron.") % [tr(c["chief"]), tr(c["epithet"]), tr(c["name"])], 15, COL_DIM))
		var cands: Array = sim.living().filter(func(o): return o.role == "")
		cands.sort_custom(func(a, b): return R.deal_value(clan_id, R.empty_terms(), a) > R.deal_value(clan_id, R.empty_terms(), b))
		for o in cands.slice(0, 6):
			var trs: String = tr(D.TRAITS[o.traits[0]]["name"])
			var who = o
			var b := _button(tr("%s \"%s\" — %s · Lore %d · Combat %d") % [tr(o.name), tr(o.epithet), trs, o.lv("lore"), o.lv("combat")], func(): _do_send_envoy(who, clan_id))
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			v.add_child(b)
	else:
		v.add_child(_label(tr("Where should %s go?") % tr(u.name), 15, COL_DIM))
		for id in R.clans:
			var c: Dictionary = R.clans[id]
			var why: String = R.envoy_block(u, id)
			var cid: String = id
			var b := _button(tr("%s — %s (%d)") % [tr(c["name"]), tr(R.stance(id)), roundi(c["relation"])] if c["met"] else tr("Unknown clan"), func(): _do_send_envoy(u, cid))
			b.disabled = why != ""
			if why != "": b.tooltip_text = tr(why)
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			v.add_child(b)
	v.add_child(_label(tr("The envoy walks there; the parley begins when they reach the village. A clan in blood feud may not be gentle with the messenger."), 13, COL_DIM))
	v.add_child(_button("Cancel", _close_modal))

## Send a trader to a clan: pick what to carry, then who carries it.
func open_trade(clan_id: String, res := "", amt := 0) -> void:
	var F = sim.folk
	var c: Dictionary = sim.rivals.clans[clan_id]
	var v := _open_modal(tr("TRADE WITH THE %s") % tr(c["name"]).to_upper(), 720)
	if res == "":
		v.add_child(_label(tr("The %s sell %s and want %s. They are %s toward us. What shall our trader carry?") % [tr(c["name"]), tr(c["sells"]), tr(c["wants"]), tr(sim.rivals.stance(clan_id)).to_lower()], 15, COL_DIM))
		for bundle in [["goods", 5], ["goods", 10], ["food", 20], ["wood", 20], ["stone", 15], ["herbs", 5]]:
			var r: String = bundle[0]
			var n: int = bundle[1]
			if r == c["sells"] or (r in ["herbs", "goods"] and sim.stock[r] <= 0): continue
			var q: Dictionary = F.quote(clan_id, r, n)
			var get_txt: String = "%d %s" % [q.values()[0], tr(q.keys()[0])] if not q.is_empty() else "-"
			var b := _button(tr("Carry %d %s (we have %d) → about %s") % [n, tr(r), sim.stock[r], get_txt], func(): open_trade(clan_id, r, n))
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.disabled = sim.stock[r] < n or q.is_empty()
			v.add_child(b)
		v.add_child(_label(tr("Our crafted goods fetch the best price, and they pay more for what they want. Friends pay better than strangers."), 13, COL_DIM))
	else:
		v.add_child(_label(tr("Who will carry %d %s to the %s?") % [amt, tr(res), tr(c["name"])], 15, COL_DIM))
		var cands: Array = sim.living().filter(func(o): return o.role == "")
		cands.sort_custom(func(a, b): return a.lv("trade") > b.lv("trade") if a.lv("trade") != b.lv("trade") else a.pos.distance_to(c["pos"]) < b.pos.distance_to(c["pos"]))
		for o in cands.slice(0, 6):
			var who = o
			var q: Dictionary = F.quote(clan_id, res, amt, o)
			var haul: String = "%d %s" % [q.values()[0], tr(q.keys()[0])] if not q.is_empty() else "-"
			var b := _button(tr("%s \"%s\" — Trade %d → about %s · %s") % [tr(o.name), tr(o.epithet), o.lv("trade"), haul, I.act(o.act)], func():
				var err: String = F.send_trader(who, clan_id, res, amt)
				_close_modal()
				if err != "": sim.popup(who.pos, tr(err), Color("#ff8080")))
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			v.add_child(b)
	v.add_child(_button("Cancel", _close_modal))

func _do_send_envoy(u, clan_id: String) -> void:
	var err: String = sim.rivals.send_envoy(u, clan_id)
	_close_modal()
	if err != "": sim.popup(u.pos, tr(err), Color("#ff8080"))
	else: sim.popup(u.pos + Vector2(0, -30), tr("Envoy to the %s") % tr(sim.rivals.clans[clan_id]["name"]), Color("#9fd0ff"), true)

var par := {}

const PAR_ROUNDS := 5

## The envoy has reached the rival village: a parley with their chieftain's LLM node.
func open_parley(u, clan_id: String) -> void:
	var R = sim.rivals
	var c: Dictionary = R.clans[clan_id]
	var v := _open_modal(tr("PARLEY · %s %s of the %s") % [tr(c["chief"]), tr(c["epithet"]), tr(c["name"])], 1080)
	par = {"u": u, "id": clan_id, "history": [], "round": 0, "busy": false, "token": modal_token, "reply": {}, "syncing": false}
	v.add_child(_label(tr("Our envoy: %s \"%s\" · %s · Lore %d · Combat %d    ·    Their mood: %s (%+d)") % [tr(u.name), tr(u.epithet), tr(D.TRAITS[u.traits[0]]["name"]), u.lv("lore"), u.lv("combat"), tr(R.stance(clan_id)), roundi(c["relation"])], 14, Color("#9fd0ff")))
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
	lcol.add_child(_header("AT THEIR FIRE"))
	var chat := _rich(330)
	chat.scroll_following = true
	lcol.add_child(chat)
	par["chat"] = chat
	chat.append_text(tr("[color=#a89878][i]%s is led to the fire of %s %s. Warriors watch from the huts.[/i][/color]\n") % [tr(u.name), tr(c["chief"]), tr(c["epithet"])])
	var rh := HBoxContainer.new()
	lcol.add_child(rh)
	var words := LineEdit.new()
	words.placeholder_text = tr("What %s says (e.g. 'our peoples should not bleed for berries')") % tr(u.name)
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rh.add_child(words)
	par["words"] = words
	words.text_submitted.connect(func(_t): _par_propose())
	rcol.add_child(_header("OUR OFFER"))
	var g := GridContainer.new()
	g.columns = 2
	rcol.add_child(g)
	g.add_child(_label("Treaty", 14, COL_DIM))
	var treaty := OptionButton.new()
	for k in R.TREATIES: treaty.add_item(tr({"none": "Exchange of goods only", "peace": "Peace pact (no raids)", "hunting_rights": "Hunting rights on their land", "alliance": "Alliance (fight and learn together)"}[k]))
	treaty.select(1)
	g.add_child(treaty)
	par["treaty"] = treaty
	par["days"] = _par_spin(g, tr("Days"), 5, 40, 15)
	g.add_child(_label("They teach us", 14, COL_DIM))
	var teach := OptionButton.new()
	teach.add_item(tr("(nothing)"))
	par["teach_ids"] = [""]
	for tid in R.teachable(clan_id):
		teach.add_item(tr(sim.evo.tech_def(tid)["name"]))
		par["teach_ids"].append(tid)
	g.add_child(teach)
	par["teach"] = teach
	teach.item_selected.connect(func(_i): if not par.get("syncing", false): par["seal"].disabled = true)
	par["tribute"] = _par_spin(g, tr("Tribute (food/day)"), 0, 10, 0)
	for r in R.RES: par["give_" + r] = _par_spin(g, tr("We give: %s") % tr(r), 0, mini(80, int(sim.stock[r])), 0)
	for r in R.RES: par["ask_" + r] = _par_spin(g, tr("We ask: %s") % tr(r), 0, 60, 0)
	var pb := _button(tr("Propose"), func(): _par_propose())
	rcol.add_child(pb)
	par["propose"] = pb
	var status := _label("", 13, COL_DIM)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rcol.add_child(status)
	par["status"] = status
	var bh := HBoxContainer.new()
	v.add_child(bh)
	var seal := _button(tr("Seal the agreement"), func(): _par_seal())
	seal.disabled = true
	seal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(seal)
	par["seal"] = seal
	bh.add_child(_button(tr("Leave the parley"), func(): _par_end(tr("%s leaves the fire of the %s without an agreement.") % [tr(u.name), tr(c["name"])])))
	status.text = tr("Make an offer. %d rounds before %s grows impatient.") % [PAR_ROUNDS, tr(c["chief"])]

func _par_spin(g: GridContainer, label: String, lo: int, hi: int, val: int) -> SpinBox:
	g.add_child(_label(label, 14, COL_DIM))
	var sp := SpinBox.new()
	sp.min_value = lo
	sp.max_value = maxi(lo, hi)
	sp.value = val
	g.add_child(sp)
	sp.value_changed.connect(func(_v): if not par.get("syncing", false): par["seal"].disabled = true)
	return sp

func _par_offer() -> Dictionary:
	var R = sim.rivals
	var raw := {"treaty": R.TREATIES[par["treaty"].selected], "days": int(par["days"].value), "tribute": int(par["tribute"].value),
		"tribe_gives": {}, "clan_gives": {}}
	for r in R.RES:
		raw["tribe_gives"][r] = int(par["give_" + r].value)
		raw["clan_gives"][r] = int(par["ask_" + r].value)
	raw["teach"] = par["teach_ids"][maxi(0, par["teach"].selected)]
	return R.sanitize_terms(raw, R.empty_terms(), par["id"])

func _par_sync(t: Dictionary) -> void:
	par["syncing"] = true
	par["treaty"].select(sim.rivals.TREATIES.find(t["treaty"]))
	par["days"].value = t["days"]
	par["tribute"].value = t["tribute"]
	par["teach"].select(maxi(0, par["teach_ids"].find(t.get("teach", ""))))
	for r in sim.rivals.RES:
		par["give_" + r].value = t["tribe_gives"][r]
		par["ask_" + r].value = t["clan_gives"][r]
	par["syncing"] = false

func _par_propose() -> void:
	if par.is_empty() or par["busy"]: return
	var R = sim.rivals
	var u = par["u"]
	var id: String = par["id"]
	var c: Dictionary = R.clans[id]
	if par["round"] >= PAR_ROUNDS:
		_par_end(tr("%s has heard enough and turns away. Our envoy heads home.") % tr(c["chief"]))
		return
	par["busy"] = true
	par["propose"].disabled = true
	par["seal"].disabled = true
	var token: int = par["token"]
	var offer := _par_offer()
	var msg: String = par["words"].text.strip_edges()
	par["words"].text = ""
	var chat: RichTextLabel = par["chat"]
	chat.append_text(tr("[color=#9fd0ff][b]%s:[/b][/color] %s[color=#8a9aa8][i](offers: %s)[/i][/color]\n") % [tr(u.name), (msg + " ") if msg != "" else "", R.terms_text(offer)])
	par["history"].append({"speaker": tr(u.name), "text": msg, "offer": R.terms_text(offer)})
	chat.append_text(tr("[color=#8a7a60][i]%s considers…[/i][/color]\n") % tr(c["chief"]))
	var ctx: Dictionary = R.parley_ctx(u, id, offer, msg, par["history"].slice(-6), par["round"])
	var fb: Dictionary = R.chief_reply(ctx, u)
	var r: Dictionary = await llm.parley(ctx, fb)
	if modal == null or modal_token != token: return
	chat.remove_paragraph(chat.get_paragraph_count() - 2)
	var checked: Dictionary = R.check_reply(id, r, offer, u, par["round"], fb)
	if str(checked.get("speech", "")) == "": checked["speech"] = fb["speech"]
	par["round"] += 1
	par["reply"] = checked
	var vcol: String = {"accept": "#b6f28a", "counter": "#ffd36b", "refuse": "#ff8a7a"}[checked["verdict"]]
	chat.append_text(tr("[color=#%s][b]%s:[/b][/color] %s\n") % [c["color"].lightened(0.35).to_html(false), tr(c["chief"]), checked["speech"]])
	chat.append_text(tr("[color=%s]  → %s: %s[/color]\n") % [vcol, tr({"accept": "Accepts", "counter": "Counter-offer", "refuse": "Refuses"}[checked["verdict"]]), R.terms_text(checked["terms"]) if checked["verdict"] != "refuse" else tr("no deal")])
	par["history"].append({"speaker": tr(c["chief"]), "text": checked["speech"], "verdict": checked["verdict"]})
	if r.get("error", "") != "": chat.append_text(tr("[color=#ff8a7a][i](cloud LLM failed: %s — used offline chieftain)[/i][/color]\n") % r["error"])
	if checked["verdict"] != "refuse": _par_sync(checked["terms"])
	par["seal"].disabled = checked["verdict"] == "refuse"
	par["seal"].text = tr("Seal: %s") % R.terms_text(checked["terms"]) if checked["verdict"] != "refuse" else tr("Seal the agreement")
	par["status"].text = tr("LLM node: %s · round %d of %d.%s") % [r.get("source", "?"), par["round"], PAR_ROUNDS, tr(" (Their reply was held to what the clan can bear.)") if checked.get("note", "") == "clamped" else ""]
	par["propose"].disabled = false
	par["busy"] = false

func _par_seal() -> void:
	var rp: Dictionary = par.get("reply", {})
	if rp.is_empty() or rp["verdict"] == "refuse": return
	var what: String = sim.rivals.seal(par["u"], par["id"], rp["terms"], par["round"])
	_par_end(tr("Hands are clasped over the fire. Agreed with the %s: %s.") % [tr(sim.rivals.clans[par["id"]]["name"]), what])

func _par_end(text: String) -> void:
	sim.rivals.end_parley(par["u"], par["id"])
	par = {}
	var v := _open_modal("Outcome", 640)
	var txt := _rich(0, true)
	txt.text = text
	v.add_child(txt)
	v.add_child(_button("Continue", func(): _close_modal(); sim.paused = false))

# ------------------------------------------------------------ legacy: the paths to victory
func _open_legacy() -> void:
	var was_paused: bool = sim.paused
	sim.paused = true
	var v := _open_modal(tr("LEGACY · Day %d") % sim.day(), 760)
	var r := _rich(0, true)
	var s := ""
	for p in sim.legacy.progress():
		var won: bool = sim.legacy.achieved.has(p["path"])
		s += tr("[color=%s][b]%s[/b][/color]%s — [i]%s[/i]\n") % ["#b6f28a" if won else "#ffd36b", p["title"], (tr("  (achieved on Day %d)") % sim.legacy.achieved[p["path"]]) if won else "", p["desc"]]
		for c in p["conds"]:
			s += tr("   [color=%s]%s %s[/color]\n") % ["#b6f28a" if c["done"] else "#a89878", "✔" if c["done"] else "○", c["text"]]
		s += "\n"
	s += tr("[color=#8a7a60]If every one of our people dies, the chronicle ends in defeat. After a victory you may keep playing.[/color]")
	r.text = s
	v.add_child(r)
	v.add_child(_button("Close", func(): _close_modal(); sim.paused = was_paused))

const FEAT_KINDS := {"invention": ["Invention", "#9ff0c8"], "wisdom": ["Wisdom", "#c8a8ff"], "find": ["Find", "#ffd36b"],
	"landmark": ["Landmark", "#ffe6a8"], "contact": ["Clan", "#9fd0ff"], "tradition": ["Tradition", "#ffd6a0"],
	"era": ["Age", "#ffb36b"], "masterpiece": ["Masterpiece", "#f0b8e0"], "outpost": ["Outpost", "#b6f28a"],
	"story": ["Happening", "#e8c8a0"], "tale": ["Tale", "#e8c070"], "hero": ["Hero", "#ffd36b"]}

## The tribe's achievements: everyday inventions (known, and hints of those still to come)
## and the record of its firsts.
func open_achievements() -> void:
	var was_paused: bool = sim.paused
	sim.paused = true
	var inv = sim.inv
	var v := _open_modal(tr("ACHIEVEMENTS · Day %d") % sim.day(), 820)
	v.add_child(_header(tr("INVENTIONS (%d of %d)") % [inv.known.size(), D.INVENTIONS.size()]))
	var r := _rich(0, true)
	var s := ""
	for kind in D.INVENTION_KINDS:
		s += "[b]%s[/b]\n" % tr(D.INVENTION_KINDS[kind])
		for d in D.INVENTIONS:
			if d["kind"] != kind: continue
			if inv.has(d["id"]):
				var k: Dictionary = inv.known[d["id"]]
				var by: String = (tr(" by %s") % tr(k["by"])) if k["by"] != "" else ""
				s += (tr("  [color=#9ff0c8]✔ %s[/color] — %s [color=#8a7a60](Day %d%s)[/color]") % [tr(d["name"]), tr(d["desc"]), k["day"], by]) + "\n"
			elif inv.needs_met(d):
				s += (tr("  [color=#d8ccb0]○ ???[/color] — [i]%s[/i] [color=#8a7a60](%d%%)[/color]") % [tr(d["hint"]), roundi(inv.frac(d["id"]) * 100)]) + "\n"
			else:
				s += (tr("  [color=#6a5e4a]○ ??? — %s[/color]") % tr(d["hint"])) + "\n"
		s += "\n"
	r.text = s
	v.add_child(r)
	v.add_child(_header(tr("THE TRIBE'S FIRSTS (%d)") % inv.feats.size()))
	var f := _rich(0, true)
	var lines: Array = []
	for e in inv.feats:
		var fk: Array = FEAT_KINDS.get(e["kind"], ["", "#d8ccb0"])
		var who: String = (" [color=#8a7a60]— %s[/color]" % tr(e["who"])) if e["who"] != "" else ""
		lines.append(tr("[color=#8a7a60]Day %d[/color]  [color=%s]%s[/color]  %s%s") % [e["day"], fk[1], tr(fk[0]), e["text"], who])
	f.text = "\n".join(lines) if not lines.is_empty() else tr("[color=#8a7a60]Nothing yet. Explore, work and learn: every first is written here.[/color]")
	v.add_child(f)
	v.add_child(_button("Close", func(): _close_modal(); sim.paused = was_paused))

# ------------------------------------------------------------ achievement celebrations
## Each of the tribe's firsts (inv.feat) pauses the game for a dialog with a picture of the
## place where it happened, what it means and, for culture entries, its source. They queue
## up and wait while any other dialog (an event, a negotiation) is open.
const SETTINGS_CFG := "user://settings.cfg"
const FEAT_SYMBOLS := {"invention": "✦", "wisdom": "✧", "find": "❖", "landmark": "▲", "contact": "☉", "tradition": "❂",
	"era": "☀", "masterpiece": "✿", "outpost": "⌂", "story": "☼", "tale": "❦", "hero": "★"}

func _feat_pref() -> bool:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_CFG) == OK: return bool(cf.get_value("ui", "feat_popups", true))
	return true

func _set_feat_pref(on: bool) -> void:
	feat_popups = on
	var cf := ConfigFile.new()
	cf.load(SETTINGS_CFG)
	cf.set_value("ui", "feat_popups", on)
	cf.save(SETTINGS_CFG)

func _on_feat(f: Dictionary) -> void:
	if feat_popups: feat_queue.append(f)

## Once a frame: notice when the achievement dialog was closed (button or Esc), and show
## the next one when nothing else is on screen.
func _feat_tick() -> void:
	if feat_token >= 0 and (modal == null or modal_token != feat_token):
		feat_token = -1
	if feat_token >= 0 or feat_token == -2: return # (-2: taking the picture)
	if feat_queue.is_empty():
		if feat_resume != null and modal == null:
			sim.paused = feat_resume
			feat_resume = null
		return
	if modal == null and sim.pending_event == "": _show_feat()

## A picture of the world around `at` (world space), drawn by a second camera that shares
## the world but not the HUD.
func _snapshot(at: Vector2) -> Texture2D:
	if snap_vp == null:
		snap_vp = SubViewport.new()
		snap_vp.size = Vector2i(640, 300)
		snap_vp.world_2d = get_viewport().world_2d
		snap_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		snap_cam = Camera2D.new()
		snap_vp.add_child(snap_cam)
		add_child(snap_vp)
		snap_cam.enabled = true
		snap_cam.make_current()
	snap_cam.position = world.iso(at) + Vector2(0, -24)
	snap_cam.zoom = Vector2(1.6, 1.6)
	world.clean = true # (just for this frame: the game is paused)
	world.overlay.queue_redraw()
	snap_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	world.clean = false
	world.overlay.queue_redraw()
	return ImageTexture.create_from_image(snap_vp.get_texture().get_image())

func _show_feat() -> void:
	var f: Dictionary = feat_queue.pop_front()
	if feat_resume == null: feat_resume = sim.paused
	sim.paused = true
	feat_token = -2
	var tex: Texture2D = await _snapshot(f["at"])
	if modal != null: # (something else opened meanwhile: wait for it)
		feat_queue.push_front(f)
		feat_token = -1
		return
	var fk: Array = FEAT_KINDS.get(f["kind"], ["Achievement", "#ffd36b"])
	var col := Color(fk[1])
	var sym: String = FEAT_SYMBOLS.get(f["kind"], "★")
	var v := _open_modal(tr("%s  ACHIEVEMENT  %s") % [sym, sym], 680)
	feat_token = modal_token
	var frame := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.BLACK
	sb.border_color = col
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(6)
	sb.shadow_color = Color(col, 0.35)
	sb.shadow_size = 10
	frame.add_theme_stylebox_override("panel", sb)
	var stack := Control.new()
	stack.custom_minimum_size = Vector2(640, 300)
	frame.add_child(stack)
	var pic := TextureRect.new()
	pic.texture = tex
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	pic.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.add_child(pic)
	var vig := TextureRect.new() # a soft vignette and a band for the caption
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0))
	g.set_color(1, Color(0, 0, 0, 0.75))
	g.set_offset(0, 0.55)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.42)
	gt.fill_to = Vector2(1.05, 1.05)
	vig.texture = gt
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(vig)
	var tag := _label("%s %s" % [sym, tr(fk[0]).to_upper()], 14, col)
	tag.position = Vector2(14, 10)
	tag.add_theme_color_override("font_shadow_color", Color.BLACK)
	stack.add_child(tag)
	var cap := _label(f["text"], 24, Color("#fff4dc"))
	cap.add_theme_color_override("font_shadow_color", Color.BLACK)
	cap.add_theme_constant_override("shadow_offset_x", 2)
	cap.add_theme_constant_override("shadow_offset_y", 2)
	cap.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cap.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	cap.offset_left = 16
	cap.offset_right = -16
	cap.offset_top = -48
	cap.offset_bottom = -10
	stack.add_child(cap)
	v.add_child(frame)
	var by: String = (tr("by %s") % tr(f["who"])) if f["who"] != "" else tr("by the whole tribe")
	v.add_child(_label(tr("Day %d · %s · the tribe's first no. %d") % [f["day"], by, sim.inv.feats.find(f) + 1], 14, COL_DIM))
	if f["desc"] != "":
		var d := _rich(0, true)
		d.text = f["desc"]
		v.add_child(d)
	if f["source"] != "" or f["history"] != "":
		var s := _rich(0, true)
		s.text = _badge(f["history"]).strip_edges() + (("  [color=#8a7a60][i]%s[/i][/color]" % (tr("Source: %s") % tr(f["source"]))) if f["source"] != "" else "")
		v.add_child(s)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var cb := CheckBox.new()
	cb.text = tr("Celebrate achievements as they happen")
	cb.button_pressed = feat_popups
	cb.toggled.connect(func(on):
		_set_feat_pref(on)
		if not on: feat_queue.clear())
	cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cb)
	var more := feat_queue.size()
	var ok := _button(tr("Next (%d more)") % more if more > 0 else tr("Continue"), func(): _close_modal())
	ok.custom_minimum_size = Vector2(160, 36)
	row.add_child(ok)
	v.add_child(row)
	ok.grab_focus()

## Real history or legend? Shown beside every Heritage entry that says.
const HISTORY_BADGES := {"real": ["Historical", "#9fd0ff"], "legend": ["Legend", "#e8c070"], "invented": ["Imagined", "#c0a8e0"]}

func _badge(h: String) -> String:
	if not HISTORY_BADGES.has(h): return ""
	return " [color=%s][%s][/color]" % [HISTORY_BADGES[h][1], tr(HISTORY_BADGES[h][0])]

## The culture's heritage: what the tribe has made, found, met, lived through and been
## told, each marked as history or legend with its source; the rest still hidden.
func open_heritage() -> void:
	var cu = sim.cult
	if not cu.on(): return
	var was_paused: bool = sim.paused
	sim.paused = true
	var c: Dictionary = cu.def
	var v := _open_modal(tr("HERITAGE · %s") % tr(c["name"]), 860)
	var head := _rich(0, true)
	var where: Array = []
	for k in ["period", "place"]:
		if c.has(k): where.append(tr(c[k]))
	head.text = ("[color=#8a7a60]%s[/color]\n" % " · ".join(where) if not where.is_empty() else "") + tr(c["desc"]) \
		+ (("\n[color=#8a7a60][i]%s[/i][/color]" % (tr("Source: %s") % tr(c["source"]))) if c.has("source") else "")
	v.add_child(head)
	for sec in cu.codex():
		var rows: Array = sec["entries"]
		var known: int = rows.filter(func(e): return e["known"]).size()
		v.add_child(_header("%s (%d / %d)" % [sec["title"].to_upper(), known, rows.size()]))
		var r := _rich(0, true)
		var lines: Array = []
		for e in rows:
			if not e["known"]:
				lines.append("[color=#6a5e4a]○ ???[/color]")
				continue
			var sub: String = (" [color=#8a7a60]— %s[/color]" % e["sub"]) if e["sub"] != "" else ""
			var line: String = "[color=#e8d8b0][b]%s[/b][/color]%s%s\n    %s" % [e["name"], sub, _badge(e["history"]), e["desc"]]
			if e["source"] != "": line += "\n    [color=#8a7a60][i]%s[/i][/color]" % (tr("Source: %s") % e["source"])
			lines.append(line)
		r.text = "\n".join(lines)
		v.add_child(r)
	v.add_child(_button("Close", func(): _close_modal(); sim.paused = was_paused))

## A victory or defeat: the storyteller's LLM node composes the saga of the game.
func _show_ending(id: String) -> void:
	var L = sim.legacy
	var path: String = L.path_of(id)
	var d: Dictionary = sim.event_def(id)
	var v := _open_modal(("☠ " if path == "defeat" else "♛ ") + d["title"], 900, path == "defeat")
	var token := modal_token
	var head := _rich(0, true)
	var ctx: Dictionary = L.saga_ctx(path)
	head.text = tr("[i]%s[/i]\n[color=#b8a888]Day %d · %s · %d living, %d fallen · %d pieces of wisdom[/color]") % [d["text"], ctx["day"], ctx["age"], ctx["people_living"], ctx["people_fallen"], ctx["wisdom"].size()]
	v.add_child(head)
	v.add_child(_header("THE SAGA"))
	var saga := _rich(0, true)
	var teller: Dictionary = ctx["storyteller"]
	saga.text = tr("[color=#8a7a60][i]%s gathers the children by the fire…[/i][/color]") % teller.get("name", tr("An elder"))
	v.add_child(saga)
	var bh := HBoxContainer.new()
	v.add_child(bh)
	var i := 0
	for o in d["options"]:
		var idx := i
		bh.add_child(_button(tr(o["label"]), func():
			var res: Dictionary = sim.resolve_event(id, idx)
			_close_modal()
			if res.get("restart", false): get_tree().reload_current_scene()
			else: sim.paused = false))
		i += 1
	var r: Dictionary = await llm.saga(ctx, L.saga_offline(ctx))
	if modal == null or modal_token != token: return
	saga.text = tr("[color=#e6b8ff][b]%s:[/b][/color] %s\n[color=#8a9aa8](%s)[/color]") % [teller.get("name", tr("An elder")), r["saga"], r.get("source", "")]
