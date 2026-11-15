## The scenario list (hand-made maps with their own tribe, clans and scripted events).
## Add a scenario by writing scenarios/<id>.gd (see the_ford.gd) and listing it here.
extends RefCounted

const D = preload("res://scripts/data.gd")
const LIST := [preload("res://scenarios/the_ford.gd")]
const DEFAULT := "the_ford"

static func ids() -> Array:
	return LIST.map(func(s): return s.INFO["id"])

static func by_id(id: String) -> Variant:
	for s in LIST:
		if s.INFO["id"] == id: return s
	return null

## The culture a map is played in by default: the scenario's own, or the default one.
static func culture_of(map_id: String) -> String:
	var s = by_id(map_id)
	return s.INFO.get("culture", "huaxia") if s != null else "huaxia"

## Load a scenario's map into data.gd (the default one if `id` is unknown).
static func apply(id := DEFAULT) -> void:
	var s = by_id(id)
	if s == null: s = by_id(DEFAULT)
	D.load_map(s.spec())
