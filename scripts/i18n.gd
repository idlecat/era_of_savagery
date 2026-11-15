## Language support (English / Simplified Chinese).
## English text is the translation key everywhere; Chinese lives in lang_zh.gd and is
## registered with Godot's TranslationServer, so `tr("...")` and auto-translated Controls
## both switch language live. Internal ids (activity strings, unit names) stay English.
extends RefCounted

const ZH = preload("res://scripts/lang_zh.gd")
const CFG := "user://settings.cfg"
const LANGS := {"en": "English", "zh": "中文"}

static var lang := "en"
static var _installed := false

static func default_lang() -> String:
	return "zh" if OS.get_locale_language() == "zh" else "en"

static func load_pref() -> String:
	var cf := ConfigFile.new()
	if cf.load(CFG) == OK: return str(cf.get_value("ui", "lang", default_lang()))
	return default_lang()

static func save_pref(l: String) -> void:
	var cf := ConfigFile.new()
	cf.load(CFG)
	cf.set_value("ui", "lang", l)
	cf.save(CFG)

static func setup(l: String) -> void:
	if not _installed:
		var t := Translation.new()
		t.locale = "zh"
		for k in ZH.STRINGS: t.add_message(k, ZH.STRINGS[k])
		TranslationServer.add_translation(t)
		_installed = true
	install_cjk_font()
	lang = l if LANGS.has(l) else "en"
	TranslationServer.set_locale("zh" if lang == "zh" else "en")

static func is_zh() -> bool:
	return lang == "zh"

static func t(s: String) -> String:
	return String(TranslationServer.translate(s))

## Activity strings are compared by game logic, so they stay English internally and are
## translated only for display (including the ones built from a prefix + a name).
const ACT_PREFIXES := ["Building ", "Renovating ", "Walking to ", "Hauling ", "Experimenting: ", "Fetching the body of ", "Carrying the body of ", "Burying ", "Watching ", "Going to trade with the ", "Trading with the "]
static func act(a: String) -> String:
	var whole := t(a)
	if whole != a: return whole
	for p in ACT_PREFIXES:
		if a.begins_with(p): return t(p + "%s") % t(a.substr(p.length()))
	if a.begins_with("No ") and a.ends_with(" nearby"):
		return t("No %s nearby") % t(a.substr(3, a.length() - 10))
	return a

## English plural suffix; Chinese has none (an empty translation would count as "missing").
static func plural_s() -> String:
	return "" if lang == "zh" else "s"

## Godot's automatic system-font fallback may pick a Japanese face for CJK text, which
## lacks some simplified characters (e.g. 杀). Put a Simplified Chinese system font first
## in the default font's fallback chain so every label and world label can render it.
static func install_cjk_font() -> void:
	var base: Font = ThemeDB.fallback_font
	for f in base.fallbacks:
		if f is SystemFont: return
	var cjk := SystemFont.new()
	# Note: "PingFang SC" resolves to the HK face on macOS, which lacks simplified glyphs.
	cjk.font_names = PackedStringArray(["Hiragino Sans GB", "STHeiti", "Microsoft YaHei", "Noto Sans CJK SC",
		"Source Han Sans SC", "WenQuanYi Micro Hei", "Arial Unicode MS"])
	var fb: Array[Font] = base.fallbacks.duplicate()
	fb.insert(0, cjk)
	base.fallbacks = fb
