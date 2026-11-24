## Game-rule configuration kept in data files: config/<name>.json (events.json: the forces
## of nature and the hardships; reactions.json: how people respond to them). A file of the
## same name in user://config/ is merged over it (keys it has replace the game's), so the
## rules can be tuned or modded without touching code. Loaded once and cached.
extends RefCounted

const DIRS := ["res://config", "user://config"]

static var _cache := {}

## The merged config `name` ({} if missing). Errors are printed and the file is skipped.
static func load_cfg(name: String) -> Dictionary:
	if _cache.has(name): return _cache[name]
	var out := {}
	for dir in DIRS:
		var path: String = "%s/%s.json" % [dir, name]
		if not FileAccess.file_exists(path): continue
		var j := JSON.new()
		if j.parse(FileAccess.get_file_as_string(path)) != OK or not j.data is Dictionary:
			push_error("config %s line %d: %s" % [path, j.get_error_line(), j.get_error_message()])
			continue
		_merge(out, j.data)
	_freeze(out)
	_cache[name] = out
	return out

## Configs are shared by everyone who loads them: read-only, so a change made by mistake
## fails loudly where it happens instead of quietly changing the rules for everyone else.
## (Copy with duplicate(true) to change one.)
static func _freeze(v) -> void:
	if v is Dictionary:
		for k in v: _freeze(v[k])
		v.make_read_only()
	elif v is Array:
		for x in v: _freeze(x)
		v.make_read_only()

## Forget cached configs (tests that change them; a mod reload).
static func reload() -> void:
	_cache.clear()

static func _merge(into: Dictionary, over: Dictionary) -> void:
	for k in over:
		if into.get(k) is Dictionary and over[k] is Dictionary: _merge(into[k], over[k])
		else: into[k] = over[k]

## A random float from a [min, max] pair (or a plain number).
static func rand_in(v) -> float:
	if v is Array: return randf_range(float(v[0]), float(v[1]))
	return float(v)

const TEXT_KEYS := ["text", "title", "label", "desc", "result", "else_result", "alert", "warn", "done", "log",
	"start_log", "end_log", "popup", "hit_popup", "out_popup", "hit_alert", "building_alert", "remember",
	"hit_remember", "name", "acts", "reason", "grudge", "speaker_default", "pro", "con", "remember_heard", "remember_stand",
	"act", "lowest_word", "arrive"]
## Keys whose values are all texts ({id: text} or {id: [texts]}).
const TEXT_TABLES := ["voices", "treasures", "warn", "titles", "happened", "outcome", "talk"]
## Keys holding lists of texts (nested lists too; numbers in them are skipped).
const TEXT_LISTS := ["acts", "words", "signs"]

## Every player-visible text in a config (strings under TEXT_KEYS, lists of them for
## "acts", the key of a [key, var names...] text, and TEXT_TABLES), for translation checks.
static func texts(v, out: Array = [], keyed := false, key := "") -> Array:
	if v is String:
		if keyed and v != "%s" and not v in out: out.append(v)
	elif v is Dictionary:
		for k in v:
			if k in TEXT_TABLES and v[k] is Dictionary:
				for t in v[k].values(): texts(t, out, true, "acts")
			else: texts(v[k], out, k in TEXT_KEYS or k in TEXT_LISTS, k)
	elif v is Array:
		if keyed and not key in TEXT_LISTS and not v.is_empty() and v[0] is String: texts(v[0], out, true) # [key, vars...]
		else:
			for x in v: texts(x, out, keyed, key)
	return out
