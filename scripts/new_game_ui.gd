## The "New Game" screen shown before the world is built. Two modes:
##   Random map — size, how many neighbouring clans, and a seed; nothing pre-configured.
##   Scenario   — a hand-made map with its own tribe, clans and scripted events.
## Either way the player picks the culture the tribe belongs to (cultures.gd packs).
## Emits `chosen` with {"map": size id | scenario id, "tribes": int, "seed": int,
## "culture": pack id or ""} and remembers the choice.
extends CanvasLayer

signal chosen(settings: Dictionary)

const MapGen = preload("res://scripts/mapgen.gd")
const Scenarios = preload("res://scripts/scenarios.gd")
const HUD = preload("res://scripts/hud.gd")
const Cultures = preload("res://scripts/cultures.gd")
const SaveGame = preload("res://scripts/save_game.gd")
const Lands = preload("res://scripts/lands.gd")
const CFG := "user://newgame.cfg"
const MODES := ["random", "scenario"]

var mode_opt: OptionButton
var map_opt: OptionButton
var tribe_opt: OptionButton
var seed_edit: LineEdit
var culture_opt: OptionButton
var land_opt: OptionButton
var land_ids: Array = [] # option index -> land id ("random" first)
var picked_land := "random"
var culture_ids: Array = [] # option index -> pack id ("" = none)
var picked_culture := "" # the player's own pick (else: the scenario's culture)
var desc: Label
var tribes_by_map := {} # remembered clan count per map size
var last := {"random": "standard", "scenario": Scenarios.DEFAULT} # remembered map per mode

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
	mode_opt = OptionButton.new()
	mode_opt.add_item(tr("Random map"))
	mode_opt.add_item(tr("Scenario"))
	mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_opt.item_selected.connect(func(_i): _fill_maps())
	_row(grid, tr("Mode"), mode_opt)
	map_opt = OptionButton.new()
	map_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_opt.item_selected.connect(func(_i):
		last[_mode()] = _map()
		_refresh_tribes())
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
	land_opt = OptionButton.new()
	land_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	land_ids = ["random"] + Lands.ids()
	land_opt.add_item(tr("Random"))
	for id in Lands.ids(): land_opt.add_item(tr(Lands.cfg()["lands"][id]["name"]))
	land_opt.tooltip_text = tr("How wooded the land is, and all that goes with it: grass, herds, weather and fires.")
	land_opt.item_selected.connect(func(i):
		picked_land = land_ids[i]
		_describe())
	_row(grid, tr("Land"), land_opt)
	culture_opt = OptionButton.new()
	culture_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	culture_ids = Cultures.ids()
	for id in culture_ids: culture_opt.add_item(tr(Cultures.by_id(id)["name"]))
	culture_ids.append("")
	culture_opt.add_item(tr("None (base game only)"))
	culture_opt.tooltip_text = tr("The people your tribe belongs to: their tools, foods, finds, heroes, happenings and folk tales.")
	culture_opt.item_selected.connect(func(i):
		picked_culture = culture_ids[i] if culture_ids[i] != "" else "none"
		_describe())
	_row(grid, tr("Culture"), culture_opt)
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
	var saves := SaveGame.slots()
	if not saves.is_empty(): # carry on with a saved game
		var lh := HBoxContainer.new()
		var pick := OptionButton.new()
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for h in saves: pick.add_item(tr("%s · Day %d · %s") % [h["slot"], int(h["day"]), str(h["saved"])])
		lh.add_child(pick)
		var lb := Button.new()
		lb.text = tr("Load")
		lb.pressed.connect(func(): chosen.emit({"load": saves[maxi(0, pick.selected)]["slot"]}))
		lh.add_child(lb)
		var cont := Button.new()
		cont.text = tr("Continue (Day %d)") % int(saves[0]["day"])
		cont.custom_minimum_size = Vector2(0, 40)
		cont.pressed.connect(func(): chosen.emit({"load": saves[0]["slot"]}))
		v.add_child(cont)
		v.add_child(lh)
	_load()
	_fill_maps()
	start.grab_focus()

func _row(grid: GridContainer, label: String, ctl: Control) -> void:
	var l := Label.new()
	l.text = label
	grid.add_child(l)
	grid.add_child(ctl)

func _mode() -> String:
	return MODES[maxi(0, mode_opt.selected)]

## The map ids the current mode offers: sizes, or scenario ids.
func _maps() -> Array:
	return MapGen.SIZE_ORDER if _mode() == "random" else Scenarios.ids()

func _map() -> String:
	var ids := _maps()
	return ids[clampi(map_opt.selected, 0, ids.size() - 1)]

func _fill_maps() -> void:
	map_opt.clear()
	var random := _mode() == "random"
	for id in _maps():
		map_opt.add_item(tr(MapGen.SIZES[id]["name"]) if random else tr(Scenarios.by_id(id).INFO["name"]))
	map_opt.select(maxi(0, _maps().find(last[_mode()])))
	_refresh_tribes()

func _on_tribes(i: int) -> void:
	tribes_by_map[_map()] = i + 1
	_describe()

func _refresh_tribes() -> void:
	var m := _map()
	tribe_opt.clear()
	if _mode() == "scenario":
		tribe_opt.add_item(str(Scenarios.by_id(m).CLANS.size()))
		tribe_opt.disabled = true
		seed_edit.editable = false
		land_opt.disabled = true # (a scenario's land is its own)
	else:
		tribe_opt.disabled = false
		seed_edit.editable = true
		land_opt.disabled = false
		var mx: int = MapGen.max_tribes(m)
		for i in mx: tribe_opt.add_item(str(i + 1))
		tribe_opt.select(clampi(int(tribes_by_map.get(m, MapGen.SIZES[m]["def"])), 1, mx) - 1)
	_describe()

func _culture() -> String:
	if picked_culture == "none": return ""
	if picked_culture != "" and picked_culture in culture_ids: return picked_culture
	var c := Scenarios.culture_of(_map()) if _mode() == "scenario" else Cultures.DEFAULT
	return c if c in culture_ids else ""

func _describe() -> void:
	var m := _map()
	var cu := _culture()
	culture_opt.select(culture_ids.find(cu))
	var cdesc := ""
	if cu != "":
		var c := Cultures.by_id(cu)
		cdesc = "\n\n" + tr(c["name"]) + ((" · " + tr(c["period"])) if c.has("period") else "") + "\n" + tr(c["desc"])
	if _mode() == "scenario":
		desc.text = tr(Scenarios.by_id(m).INFO["desc"]) + cdesc
		return
	var sz: Dictionary = MapGen.SIZES[m]
	var ldesc := ""
	if picked_land != "random": ldesc = "\n\n" + tr(Lands.cfg()["lands"][picked_land]["name"]) + ": " + tr(Lands.cfg()["lands"][picked_land]["desc"])
	desc.text = tr("A new land every time, with nothing set in advance: %d × %d paces, rivers and their fords, a tribe of strangers and %d clans placed at random among forests, herds and landmarks.") % [int(sz["w"]), int(sz["h"]), tribe_opt.selected + 1] + ldesc + cdesc

func _start() -> void:
	var m := _map()
	var random := _mode() == "random"
	var s := {"map": m, "tribes": tribe_opt.selected + 1 if random else 0,
		"seed": int(seed_edit.text) if seed_edit.text.strip_edges().is_valid_int() else randi() % 1000000, "culture": _culture(),
		"land": picked_land}
	_save(s)
	chosen.emit(s)

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG) != OK: return
	var m := str(cf.get_value("new_game", "map", Scenarios.DEFAULT))
	var random := MapGen.SIZES.has(m)
	mode_opt.select(0 if random else 1)
	if random or Scenarios.by_id(m) != null: last["random" if random else "scenario"] = m
	last["random"] = str(cf.get_value("new_game", "random_map", last["random"]))
	tribes_by_map = cf.get_value("new_game", "tribes_by_map", {})
	picked_culture = str(cf.get_value("new_game", "culture", ""))
	if bool(cf.get_value("new_game", "keep_seed", false)): seed_edit.text = str(cf.get_value("new_game", "seed", ""))
	picked_land = str(cf.get_value("new_game", "land", "random"))
	if not picked_land in land_ids: picked_land = "random"
	land_opt.select(land_ids.find(picked_land))

func _save(s: Dictionary) -> void:
	var cf := ConfigFile.new()
	cf.set_value("new_game", "map", s["map"])
	cf.set_value("new_game", "random_map", last["random"])
	cf.set_value("new_game", "tribes_by_map", tribes_by_map)
	cf.set_value("new_game", "seed", s["seed"])
	cf.set_value("new_game", "culture", picked_culture)
	cf.set_value("new_game", "land", picked_land)
	cf.set_value("new_game", "keep_seed", seed_edit.text.strip_edges() != "")
	cf.save(CFG)
