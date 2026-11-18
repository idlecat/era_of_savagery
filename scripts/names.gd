## Names for the newborn once the culture's own names are used up: built from parts in
## config/names.json (nature: Little Fox / 小狐; clan: Jiang Song / 姜松). A name is its
## English form, which is also its translation key: install() registers the Chinese form of
## every combination, so tr(u.name) works for any of them (also in a loaded game).
extends RefCounted

const I = preload("res://scripts/i18n.gd")

static var _table := {} # every combination: English -> Chinese
static var _by_pattern := {} # pattern id -> [English names]

static func _cfg() -> Dictionary: return preload("res://scripts/config.gd").load_cfg("names")

## Build every combination once and teach the Chinese translation all of them.
static func install() -> void:
	if not _table.is_empty(): return
	var C := _cfg()
	for p in C.get("patterns", []):
		var list: Array = []
		var form: Array = p.get("form", [])
		if form.size() != 2: continue
		for a in C.get(form[0], []):
			for b in C.get(form[1], []):
				var en := _fill(str(p["en"]), a, b)
				var zh := _fill(str(p["zh"]), a, b, true)
				if en == "" or _table.has(en) or I.ZH.STRINGS.has(en): continue # (two parts spelled alike, or already a word of the game: "Wild Grain" is a find)
				_table[en] = zh
				list.append(en)
		_by_pattern[p.get("id", "")] = list
	I.add_strings(_table)

## "{0} {1p}": {n} is part n's English (Chinese with zh), {np} its pinyin (part[2]).
static func _fill(f: String, a: Array, b: Array, zh := false) -> String:
	var parts := [a, b]
	for i in 2:
		var pt: Array = parts[i]
		f = f.replace("{%dp}" % i, str(pt[2]) if pt.size() > 2 else str(pt[0]))
		f = f.replace("{%d}" % i, str(pt[1]) if zh and pt.size() > 1 else str(pt[0]))
	return f

## A new name not in `taken` (a Dictionary of names already given).
static func pick(taken: Dictionary) -> String:
	install()
	var pats: Array = _cfg().get("patterns", [])
	var total := 0.0
	for p in pats: total += float(p.get("weight", 1))
	for attempt in 80:
		var r := randf() * total
		var pid := ""
		for p in pats:
			r -= float(p.get("weight", 1))
			if r <= 0.0:
				pid = p.get("id", "")
				break
		var list: Array = _by_pattern.get(pid, [])
		if list.is_empty(): continue
		var nm: String = list.pick_random()
		if not taken.has(nm): return nm
	for nm in _table: # (nearly all given: the first left)
		if not taken.has(nm): return nm
	var n := taken.size() + 1
	while taken.has("Child %d" % n): n += 1
	return "Child %d" % n

## How many names the parts can make.
static func count() -> int:
	install()
	return _table.size()
