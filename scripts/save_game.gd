## Saving and loading a game. A save holds the settings the world was made from (map or
## scenario, clans, seed, culture: the map itself is rebuilt from them, it is
## deterministic) and the whole simulation, written by reflection: every script variable
## of `sim`, its sub-systems and the entities, except the config-derived ones (UPPERCASE
## names: they are loaded fresh, so a tuned config applies to old saves). Objects are kept as a graph, so
## an entity referenced from two places is still one entity after loading.
##
## Files: user://saves/<slot>.sav (zstd-compressed Variant, no objects inside) and
## <slot>.json (a small header for the save list). For a game master: write(), read(),
## slots().
extends RefCounted

const E = preload("res://scripts/entities.gd")
const DIR := "user://saves"
const VERSION := 1

static func path_of(slot: String) -> String: return "%s/%s.sav" % [DIR, slot]

## Save `sim` (made from `settings`) into `slot`. `extra` rides along (the camera...).
## Returns "" or an error.
static func write(slot: String, sim, settings: Dictionary, extra := {}) -> String:
	if not _slot_ok(slot): return "Bad slot name"
	DirAccess.make_dir_recursive_absolute(DIR)
	var head := header(sim, settings)
	head["slot"] = slot
	var data := {"version": VERSION, "head": head, "settings": settings, "extra": extra, "sim": encode(sim)}
	var f := FileAccess.open_compressed(path_of(slot), FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null: return "Could not write the save (%d)" % FileAccess.get_open_error()
	f.store_var(data)
	f.close()
	var jf := FileAccess.open("%s/%s.json" % [DIR, slot], FileAccess.WRITE)
	if jf:
		jf.store_string(JSON.stringify(head))
		jf.close()
	return ""

## What the save list shows.
static func header(sim, settings: Dictionary) -> Dictionary:
	return {"day": sim.day(), "pop": sim.living().size(), "era": sim.evo.era, "map": settings.get("map", ""),
		"culture": settings.get("culture", ""), "saved": Time.get_datetime_string_from_system(false, true),
		"unix": Time.get_unix_time_from_system(), "version": VERSION}

## The save in `slot` ({} if missing or unreadable): {"settings", "sim", "extra", "head"}.
static func read(slot: String) -> Dictionary:
	if not _slot_ok(slot) or not FileAccess.file_exists(path_of(slot)): return {}
	var f := FileAccess.open_compressed(path_of(slot), FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null: return {}
	var data = f.get_var(false) # (never objects from a file)
	f.close()
	if not data is Dictionary or int(data.get("version", 0)) != VERSION or not data.get("settings") is Dictionary: return {}
	return data

## The saves there are, newest first: [{slot, day, pop, era, map, saved, unix}].
static func slots() -> Array:
	var out: Array = []
	var d := DirAccess.open(DIR)
	if d == null: return out
	for fn in d.get_files():
		if not fn.ends_with(".json"): continue
		var h = JSON.parse_string(FileAccess.get_file_as_string("%s/%s" % [DIR, fn]))
		if h is Dictionary and FileAccess.file_exists(path_of(fn.get_basename())):
			h["slot"] = fn.get_basename()
			out.append(h)
	out.sort_custom(func(a, b): return float(a.get("unix", 0)) > float(b.get("unix", 0)))
	return out

static func remove(slot: String) -> void:
	if not _slot_ok(slot): return
	DirAccess.remove_absolute(path_of(slot))
	DirAccess.remove_absolute("%s/%s.json" % [DIR, slot])

static func _slot_ok(slot: String) -> bool:
	return slot != "" and slot.length() <= 40 and slot.is_valid_filename() and not ".." in slot

# ------------------------------------------------------------ the object graph
## Entity classes that can be made anew on load (the sub-systems are filled in place).
static func _classes() -> Dictionary:
	var out := {}
	var es: Script = load("res://scripts/entities.gd")
	var m: Dictionary = es.get_script_constant_map()
	for k in m:
		if m[k] is GDScript: out[k] = m[k]
	return out

static func _cls_name(o: Object, classes: Dictionary) -> String:
	var s = o.get_script()
	if s == null: return ""
	for k in classes:
		if classes[k] == s: return k
	return s.resource_path # (a sub-system: "res://scripts/<x>.gd")

static func _saved(name: String) -> bool:
	return name != name.to_upper()

static func encode(root: Object) -> Dictionary:
	var ctx := {"ids": {}, "classes": _classes()}
	return _enc(root, ctx)

static func _enc(v, ctx: Dictionary):
	match typeof(v):
		TYPE_OBJECT:
			if v == null or not is_instance_valid(v) or v is Node or v is Resource: return null
			if ctx["ids"].has(v): return {"__ref": ctx["ids"][v]}
			var cn := _cls_name(v, ctx["classes"])
			if cn == "": return null
			var id: int = ctx["ids"].size()
			ctx["ids"][v] = id
			var out := {"__cls": cn, "__id": id}
			for p in v.get_property_list():
				if p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE and _saved(p["name"]):
					out[p["name"]] = _enc(v.get(p["name"]), ctx)
			return out
		TYPE_DICTIONARY:
			var d := {}
			for k in v: d[k] = _enc(v[k], ctx)
			return d
		TYPE_ARRAY:
			var a: Array = []
			for x in v: a.append(_enc(x, ctx))
			return a
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID: return null
	return v

## Fill `root` (a fresh sim after new_game()) from encode()'s output.
static func decode_into(root: Object, data: Dictionary) -> void:
	var ctx := {"objs": {}, "classes": _classes()}
	_dec(data, root, ctx)

static func _dec(v, existing, ctx: Dictionary):
	if v is Dictionary:
		if v.has("__ref"): return ctx["objs"].get(int(v["__ref"]))
		if v.has("__cls"):
			var cn: String = v["__cls"]
			var o: Object = null
			if existing is Object and existing != null and _cls_name(existing, ctx["classes"]) == cn: o = existing
			elif ctx["classes"].has(cn): o = ctx["classes"][cn].new()
			if o == null: return existing
			ctx["objs"][int(v["__id"])] = o
			var props := {}
			for p in o.get_property_list():
				if p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE: props[p["name"]] = true
			for k in v:
				if k.begins_with("__") or not props.has(k) or not _saved(k): continue
				var cur = o.get(k)
				var val = _dec(v[k], cur, ctx)
				if cur is Array and cur.is_typed() and val is Array: cur.assign(val)
				else: o.set(k, val)
			return o
		var d := {}
		for k in v: d[k] = _dec(v[k], null, ctx)
		return d
	if v is Array:
		var a: Array = []
		for x in v: a.append(_dec(x, null, ctx))
		return a
	return v
