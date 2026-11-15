## The "New Game" screen shown before the world is built: classic map or a random map
## of a chosen size, how many neighbouring clans, and a seed. Emits `chosen` with
## {"map": "classic"|size id, "tribes": int, "seed": int} and remembers the choice.
extends CanvasLayer

signal chosen(settings: Dictionary)

const MapGen = preload("res://scripts/mapgen.gd")
const HUD = preload("res://scripts/hud.gd")
const CFG := "user://newgame.cfg"
const MAPS := ["classic", "small", "standard", "large", "huge"]

var map_opt: OptionButton
var tribe_opt: OptionButton
var seed_edit: LineEdit
var desc: Label
var tribes_by_map := {} # remembered clan count per map size

func _ready() -> void:
	layer = 10
	var bg := ColorRect.new()
	bg.color = Color("#14100c")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.theme = HUD._make_theme()
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)
	var title := Label.new()
	title.text = tr("Era of Savagery · Clan Chronicles")
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", HUD.COL_ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := Label.new()
	sub.text = tr("NEW GAME")
	sub.add_theme_color_override("font_color", HUD.COL_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 10)
	v.add_child(grid)
	map_opt = OptionButton.new()
	for m in MAPS:
		if m == "classic": map_opt.add_item(tr("Classic (hand-made)"))
		else: map_opt.add_item(tr("Random · %s") % tr(MapGen.SIZES[m]["name"]))
	map_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_opt.item_selected.connect(func(_i): _refresh_tribes())
	_row(grid, tr("Map"), map_opt)
	tribe_opt = OptionButton.new()
	tribe_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tribe_opt.item_selected.connect(_on_tribes)
	_row(grid, tr("Neighbouring clans"), tribe_opt)
	var sh := HBoxContainer.new()
	seed_edit = LineEdit.new()
	seed_edit.placeholder_text = tr("random")
	seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_edit.tooltip_text = tr("The same map, clan count and seed always make the same world. Leave empty for a new one each time.")
	sh.add_child(seed_edit)
	var dice := Button.new()
	dice.text = tr("Roll")
	dice.pressed.connect(func(): seed_edit.text = str(randi() % 1000000))
	sh.add_child(dice)
	_row(grid, tr("Seed"), sh)
	desc = Label.new()
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(480, 0)
	desc.add_theme_color_override("font_color", HUD.COL_DIM)
	v.add_child(desc)
	var start := Button.new()
	start.text = tr("Begin")
	start.custom_minimum_size = Vector2(0, 44)
	start.add_theme_font_size_override("font_size", 18)
	start.pressed.connect(_start)
	v.add_child(start)
	_load()
	_refresh_tribes()
	start.grab_focus()

func _row(grid: GridContainer, label: String, ctl: Control) -> void:
	var l := Label.new()
	l.text = label
	grid.add_child(l)
	grid.add_child(ctl)

func _on_tribes(i: int) -> void:
	tribes_by_map[_map()] = i + 1
	_describe()

func _map() -> String:
	return MAPS[maxi(0, map_opt.selected)]

func _refresh_tribes() -> void:
	var m := _map()
	tribe_opt.clear()
	if m == "classic":
		tribe_opt.add_item("6")
		tribe_opt.disabled = true
		seed_edit.editable = false
	else:
		tribe_opt.disabled = false
		seed_edit.editable = true
		var mx: int = MapGen.max_tribes(m)
		for i in mx: tribe_opt.add_item(str(i + 1))
		tribe_opt.select(clampi(int(tribes_by_map.get(m, MapGen.SIZES[m]["def"])), 1, mx) - 1)
	_describe()

func _describe() -> void:
	var m := _map()
	if m == "classic":
		desc.text = tr("The hand-made land of the bonfire: the river and its ford, the Red Ochre and Heron clans close by, four more clans in the far reaches.")
		return
	var sz: Dictionary = MapGen.SIZES[m]
	desc.text = tr("A new land every time: %d × %d paces, a river with one ford, %d clans placed at random among forests, herds and landmarks.") % [int(sz["w"]), int(sz["h"]), tribe_opt.selected + 1]

func _start() -> void:
	var m := _map()
	var s := {"map": m, "tribes": tribe_opt.selected + 1 if m != "classic" else 6,
		"seed": int(seed_edit.text) if seed_edit.text.strip_edges().is_valid_int() else randi() % 1000000}
	_save(s)
	chosen.emit(s)

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG) != OK: return
	map_opt.select(maxi(0, MAPS.find(str(cf.get_value("new_game", "map", "classic")))))
	tribes_by_map = cf.get_value("new_game", "tribes_by_map", {})
	if bool(cf.get_value("new_game", "keep_seed", false)): seed_edit.text = str(cf.get_value("new_game", "seed", ""))

func _save(s: Dictionary) -> void:
	var cf := ConfigFile.new()
	cf.set_value("new_game", "map", s["map"])
	cf.set_value("new_game", "tribes_by_map", tribes_by_map)
	cf.set_value("new_game", "seed", s["seed"])
	cf.set_value("new_game", "keep_seed", seed_edit.text.strip_edges() != "")
	cf.save(CFG)
