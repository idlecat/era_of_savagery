## Check culture packs: schema errors and texts zh.json does not translate yet.
##   godot --headless --path . --script res://tools/check_culture.gd [-- --pack=res://cultures/<id>] [--skeleton]
## --skeleton prints a zh.json with every untranslated text mapped to "" (fill it in and
## merge it into the pack's zh.json). Exit code 1 if any pack has errors or missing texts.
extends SceneTree

const Cultures = preload("res://scripts/cultures.gd")

func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var dirs: Array = []
	if args.has("pack"): dirs.append(args["pack"].trim_suffix("/"))
	else:
		for root in Cultures.DIRS:
			if DirAccess.dir_exists_absolute(root):
				for sub in DirAccess.get_directories_at(root): dirs.append(root + "/" + sub)
	var bad := 0
	for d in dirs:
		var r := Cultures.load_pack(d)
		var missing: Array = Cultures.missing_zh(r["def"]) if r["errors"].is_empty() else []
		print("%s: %s" % [d, "OK" if r["errors"].is_empty() and missing.is_empty() else "%d errors, %d untranslated" % [r["errors"].size(), missing.size()]])
		for e in r["errors"]: print("   error  ", e)
		for m in missing: print("   no zh  ", m)
		if args.has("skeleton") and not missing.is_empty():
			var sk := {}
			for m in missing: sk[m.trim_suffix("  (placeholders differ)")] = ""
			print(JSON.stringify(sk, "  "))
		if not r["errors"].is_empty() or not missing.is_empty(): bad += 1
	quit(1 if bad > 0 else 0)
