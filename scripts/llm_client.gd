## Macro Node Layer (PRD 3.1): async LLM calls, only at contract nodes
## (negotiation + emergency awakening). Never called per-frame.
## Speaks the OpenAI-compatible chat/completions protocol, which DeepSeek, GLM (Zhipu)
## and Ollama all expose. Falls back to the offline persona engine on any failure.
extends Node

const Persona = preload("res://scripts/persona_engine.gd")
const D = preload("res://scripts/data.gd")
const I = preload("res://scripts/i18n.gd")
const CFG_PATH := "user://llm_settings.cfg"

const PRESETS := {
	"offline":  {"label": "Offline Persona Engine (no API)", "base_url": "", "model": "", "env": ""},
	"deepseek": {"label": "DeepSeek", "base_url": "https://api.deepseek.com", "model": "deepseek-chat", "env": "DEEPSEEK_API_KEY"},
	"glm":      {"label": "GLM - Zhipu BigModel (CN)", "base_url": "https://open.bigmodel.cn/api/paas/v4", "model": "glm-4-flash", "env": "ZHIPU_API_KEY"},
	"glm_intl": {"label": "GLM - Z.ai (international, pay-as-you-go)", "base_url": "https://api.z.ai/api/paas/v4", "model": "glm-4.5-flash", "env": "ZAI_API_KEY"},
	"zai_coding": {"label": "GLM - Z.ai Coding Plan", "base_url": "https://api.z.ai/api/coding/paas/v4", "model": "glm-5.3", "env": "ZAI_API_KEY"},
	"ollama":   {"label": "Ollama (local)", "base_url": "http://localhost:11434/v1", "model": "qwen2.5:7b", "env": ""},
	"custom":   {"label": "Custom OpenAI-compatible", "base_url": "", "model": "", "env": "LLM_API_KEY"},
}
const PRESET_ORDER := ["offline", "deepseek", "glm", "glm_intl", "zai_coding", "ollama", "custom"]

var provider := "offline"
var base_url := ""
var model := ""
var api_key := ""
var timeout_sec := 60.0
var sim # set by main; used for the LLM-call counter
var last_error := ""

func _ready() -> void:
	load_settings()

func load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) == OK:
		provider = cf.get_value("llm", "provider", "offline")
		base_url = cf.get_value("llm", "base_url", "")
		model = cf.get_value("llm", "model", "")
		api_key = cf.get_value("llm", "api_key", "")
	if not PRESETS.has(provider): provider = "offline"
	if base_url == "": base_url = PRESETS[provider]["base_url"]
	if model == "": model = PRESETS[provider]["model"]
	if api_key == "": api_key = env_key()

func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("llm", "provider", provider)
	cf.set_value("llm", "base_url", base_url)
	cf.set_value("llm", "model", model)
	# Only persist a key the player typed in; env-provided keys stay in the environment.
	cf.set_value("llm", "api_key", "" if api_key == env_key() else api_key)
	cf.save(CFG_PATH)

func env_key() -> String:
	var k := ""
	var env_name: String = PRESETS.get(provider, {}).get("env", "")
	if env_name != "": k = OS.get_environment(env_name)
	if k == "": k = OS.get_environment("LLM_API_KEY")
	return k

func is_online() -> bool:
	return provider != "offline"

func label() -> String:
	return tr("Offline persona engine") if provider == "offline" else "%s · %s" % [PRESETS[provider]["label"], model]

# ------------------------------------------------------------ prompts
const RULES := """You MUST reply with ONLY one JSON object, no markdown, in this exact shape:
{"speech": "<2-4 sentences, in character, addressed to the Great Chieftain>",
 "blueprint": {
   "plan_id": "<snake_case name for the plan>",
   "crew_size": <int 1-%d, including yourself>,
   "capacity_target": <int 2-15, people the new settlement should house>,
   "focus": "<one of: %s>",
   "steps": [ <ordered steps, 3-7 of them> ],
   "abort_conditions": [ <from: "enemy_attack", "hp_below_<N>%%", "natural_disaster"> ]
 }}
Allowed steps (executed by the game engine in order, nothing else is understood):
  {"action": "gather_wood", "target_amount": <10-120>}
  {"action": "gather_food", "target_amount": <10-60>}
  {"action": "build", "structure": "<structure id>", "count": <1-4>}
  {"action": "ritual", "duration_sec": <5-30>}
Structure ids and wood costs: %s. hut houses 3, large_hut houses 5, so huts should roughly cover capacity_target. Missing wood is gathered automatically before each build.
Your personality MUST shape both your tone and the ORDER/CHOICE of steps (cautious: walls first, start small; belligerent: bold, big, bonfire and weapons, skip walls; devout: rituals and shrines; gluttonous: food first; lazy: as little as possible).
Mention at least one memory from your memory_stream naturally. Speak with primal, vivid language; no modern words.
If the Chieftain set terms, honor them; you may grumble in speech if they clash with your nature."""

const RESEARCH_RULES := """The Chieftain asks you to lead a RESEARCH Task Contract: seek one new piece of wisdom for the tribe.
You MUST reply with ONLY one JSON object, no markdown, in this exact shape:
{"speech": "<2-4 sentences, in character, addressed to the Great Chieftain: which idea you want to pursue and why>",
 "blueprint": {
   "kind": "research",
   "plan_id": "<snake_case name>",
   "tech": "<id of ONE idea from ideas_within_reach>",
   "crew_size": <int 1-%d, including yourself>,
   "steps": [ <ordered steps, 2-5 of them, at least one experiment> ],
   "abort_conditions": [ <from: "enemy_attack", "hp_below_<N>%%"> ]
 }}
Allowed steps: {"action": "gather_wood"|"gather_food", "target_amount": <5-60>}, {"action": "gather_stone", "target_amount": <5-40>} (only if stone_quarrying_possible),
  {"action": "experiment", "duration_sec": <8-45>}, {"action": "ritual", "duration_sec": <4-30>}.
Pick the idea that fits YOUR personality and memories, unless the Chieftain names one. Describe the idea only in words your tribe could use - you have not discovered it yet.
Mention at least one memory from your memory_stream naturally. Primal, vivid language; no modern words."""

const WAR_RULES := """The Chieftain asks you to lead a WAR PARTY (a Task Contract) against a neighbouring clan.
You MUST reply with ONLY one JSON object, no markdown, in this exact shape:
{"speech": "<2-4 sentences, in character, addressed to the Great Chieftain: how you will fight and why>",
 "blueprint": {
   "kind": "war",
   "plan_id": "<snake_case name>",
   "target": "<id of ONE clan from enemies_known>",
   "objective": "loot" | "burn" | "break",
   "crew_size": <int 2-%d, including yourself>,
   "steps": [ <ordered: optional {"action": "war_dance", "duration_sec": 4-20}, optional {"action": "scout", "duration_sec": 4-25}, then {"action": "assault"}, {"action": "<objective>"}, {"action": "return"}> ],
   "abort_conditions": [ "heavy_losses", optional "hp_below_<N>%%" ]
 }}
Objectives: loot = carry off their food and wood; burn = burn their huts (they shrink, they hate us); break = hunt down their warriors so they cannot raid for many days.
Scouting first means fewer defenders surprise us; a war dance strengthens our spears. Your personality MUST shape the plan (cautious: scout, small risks, call off early; belligerent: dance, burn, never stop; devout: dance for the spirits; gluttonous: loot; lazy: quick and small).
If you think the war is foolish, say so in your speech - but still give a plan. Honour the Chieftain's terms. Mention a memory naturally. Primal, vivid language; no modern words."""

func _structure_costs() -> String:
	var parts: Array = []
	for k in D.CONTRACT_STRUCTURES:
		var sd: Dictionary = D.STRUCTURES[k]
		if sd.has("tech") and sim and not sim.has_tech(sd["tech"]): continue
		parts.append("%s=%d" % [k, sd["wood"]])
	return ", ".join(parts)

func _persona_header(leader: Dictionary, world: Dictionary = {}) -> String:
	var h := "You are %s, \"%s\", a member of a prehistoric tribe at the dawn of civilization, where saber-toothed tigers and great beasts roam. Your personality: %s.\n" % [leader["name"], leader["epithet"], "; ".join(leader["personality"])]
	if not world.is_empty():
		h += "Your tribe lives in the %s. Its culture is %s%s. It knows: %s.\n" % [world["age"], world["tribe_culture"],
			("; its traditions: " + ", ".join(world["traditions"])) if not world["traditions"].is_empty() else "",
			", ".join(world["known_wisdom"]) if not world["known_wisdom"].is_empty() else "nothing beyond stone, wood and fire"]
		for nb in world.get("neighbors", []):
			h += "A neighbouring clan, the %s (led by %s), is %s toward your tribe. Their ways: %s%s\n" % [nb["clan"], nb["chieftain"], nb["stance"].to_lower(), nb["their_ways"],
				(" They hold these wrongs against you: " + "; ".join(nb["wrongs_remembered"]) + ".") if not nb["wrongs_remembered"].is_empty() else ""]
		h += "Speak only of what your tribe knows. You have NO words for: %s - never mention them.\n" % ", ".join(world["unknown_things_you_have_no_words_for"])
	if I.is_zh():
		h += "LANGUAGE: write \"speech\" and every option \"label\" in Simplified Chinese (简体中文), in a primal, vivid voice. Keep all JSON keys, action names, structure ids, effect ids and tech ids exactly as specified, in English.\n"
	return h

# ------------------------------------------------------------ negotiation (Phase 1)
## Returns {"speech", "blueprint", "source", "error"}.
func negotiate(ctx: Dictionary) -> Dictionary:
	_count_call()
	if not is_online():
		await get_tree().create_timer(0.6).timeout
		var r := Persona.propose(ctx)
		r["source"] = "offline"
		return r
	var research: bool = ctx.get("kind", "settle") == "research"
	var system: String = _persona_header(ctx["leader"], ctx.get("world", {}))
	if research: system += RESEARCH_RULES % mini(4, ctx.get("max_crew", 4))
	elif ctx.get("kind", "settle") == "war": system += WAR_RULES % ctx.get("max_crew", 6)
	else: system += RULES % [ctx.get("max_crew", 5), ", ".join(D.FOCUSES), _structure_costs()]
	var user := {
		"directive": ctx["directive"],
		"your_profile": ctx["leader"],
		"target_environment": ctx["env"],
		"chieftain_terms": ctx["terms"] if ctx.get("terms_set", false) else "none - propose your own",
		"ideas_within_reach": ctx.get("candidates", []) if research else null,
		"conversation_so_far": ctx.get("history", []),
		"your_previous_blueprint": _strip_private(ctx.get("previous", {})),
		"chieftain_says_now": ctx.get("player_message", "") if ctx.get("player_message", "") != "" else "(Chieftain awaits your proposal)",
	}
	var res := await chat_json(system, JSON.stringify(user))
	if res["ok"] and res["data"] is Dictionary and res["data"].get("speech") is String and res["data"].get("blueprint") is Dictionary:
		return {"speech": res["data"]["speech"], "blueprint": res["data"]["blueprint"], "source": label(), "error": ""}
	var fb := Persona.propose(ctx)
	fb["source"] = "offline fallback"
	fb["error"] = res.get("error", "invalid JSON shape")
	return fb

# ------------------------------------------------------------ emergency awakening (Phase 4)
## Returns {"speech", "options": [{label, effect}], "source", "error"}.
func emergency(ctx: Dictionary) -> Dictionary:
	_count_call()
	var allowed: Array = ctx["allowed"]
	var fallback := Persona.emergency(ctx)
	if not is_online():
		await get_tree().create_timer(0.6).timeout
		fallback["source"] = "offline"
		return fallback
	var fx: Array = []
	for e in allowed: fx.append("\"%s\" = %s" % [e, ctx["effects"][e]])
	var system: String = _persona_header(ctx["leader"], ctx.get("world", {})) + """You are leading a Task Contract and an emergency just interrupted the work.
Give the Great Chieftain an urgent, in-character report (2-3 sentences) that reflects your personality and memories, then offer 2-3 choices.
Reply with ONLY one JSON object: {"speech": "<report>", "options": [{"label": "<short in-character choice>", "effect": "<effect id>"}]}
Each effect MUST be one of: %s
Order options by what YOU would prefer.""" % "; ".join(fx)
	var user := {"situation": ctx["summary"], "your_profile": ctx["leader"]}
	var res := await chat_json(system, JSON.stringify(user))
	if res["ok"] and res["data"] is Dictionary and res["data"].get("speech") is String and res["data"].get("options") is Array:
		var opts: Array = []
		var seen := {}
		for o in res["data"]["options"]:
			if o is Dictionary and str(o.get("effect", "")) in allowed and not seen.has(o["effect"]):
				seen[o["effect"]] = true
				opts.append({"effect": o["effect"], "label": str(o.get("label", o["effect"])).left(90)})
		for o in fallback["options"]: # guarantee at least the safe options exist
			if not seen.has(o["effect"]) and (opts.size() < 2 or o["effect"] == "retreat"):
				seen[o["effect"]] = true
				opts.append(o)
		return {"speech": res["data"]["speech"], "options": opts, "source": label(), "error": ""}
	fallback["source"] = "offline fallback"
	fallback["error"] = res.get("error", "invalid JSON shape")
	return fallback

# ------------------------------------------------------------ diplomacy: a rival chief's node
## One round of parley. ctx from rivals.parley_ctx(); fallback = the offline chief's reply.
## Returns {"speech", "verdict", "terms", "source", "error"} (terms still untrusted).
func parley(ctx: Dictionary, fallback: Dictionary) -> Dictionary:
	_count_call()
	if not is_online():
		await get_tree().create_timer(0.6).timeout
		var r := fallback.duplicate(true)
		r["source"] = "offline"
		r["error"] = ""
		return r
	var ch: Dictionary = ctx["chief"]
	var system := """You are %s, "%s", chieftain of the %s, a prehistoric clan. Your people: %s Your clan's spirit is %s.
Toward the neighbouring tribe whose envoy now stands at your fire you feel: %s (%d on a scale of -100 to 100).%s%s
Speak to the envoy in character, 1-3 vivid sentences, as a proud chieftain would. Weigh the offer for your clan's interests and honour.
Your inclination, judged from your clan's needs: %s. You may be moved a little by the envoy's words and manner, but do not give your clan away.
Treaty ids: "none" (only an exchange of goods), "peace" (no raids between our peoples while it lasts; "tribute" = food the envoy's tribe pays you each day), "hunting_rights" (their people may hunt and gather on your lands without offence). Resources: food, wood, stone.
Your clan may also teach them one secret ("teach": a wisdom id from you_could_teach, or ""). Secrets are precious - ask a high price, or refuse.
Reply with ONLY one JSON object: {"speech": "<what you say>", "verdict": "accept" | "counter" | "refuse", "terms": {"treaty": "<id>", "days": <5-40>, "tribute": <0-10>, "teach": "<id or empty>", "tribe_gives": {"food": n, "wood": n, "stone": n}, "clan_gives": {"food": n, "wood": n, "stone": n}}}
"tribe_gives" is what the envoy's tribe hands over, "clan_gives" what your clan hands over. For "accept", repeat the offer as terms. For "counter", give the terms you WOULD accept. They cannot give more than they have.""" % [
		ch["name"], ch["epithet"], ch["clan"], ch["ways"], ch["culture"], ch["stance"].to_lower(), ch["relation"],
		(" You remember these wrongs: " + "; ".join(ch["wrongs_remembered"]) + ".") if not ch["wrongs_remembered"].is_empty() else "",
		(" Treaties in force: " + ch["treaties_in_force"] + ".") if ch["treaties_in_force"] != "" else "",
		ctx["inclination"]]
	if I.is_zh():
		system += "\nLANGUAGE: write \"speech\" in Simplified Chinese (简体中文), in a primal, vivid voice. Keep JSON keys and ids in English."
	var user := {
		"the_envoy": ctx["envoy"], "envoy_says": ctx["envoy_says"] if ctx["envoy_says"] != "" else "(says nothing more)",
		"offer": ctx["offer"], "offer_in_words": ctx["offer_text"], "their_tribe": ctx["their_tribe"],
		"your_clan": {"people": ch["people"], "warriors": ch["warriors"], "season": ch["season"]},
		"you_could_teach": ctx.get("you_could_teach", []),
		"conversation_so_far": ctx["history"],
	}
	var res := await chat_json(system, JSON.stringify(user))
	if res["ok"] and res["data"] is Dictionary and res["data"].get("speech") is String:
		var d: Dictionary = res["data"]
		d["source"] = label()
		d["error"] = ""
		return d
	var fb := fallback.duplicate(true)
	fb["source"] = "offline fallback"
	fb["error"] = res.get("error", "invalid JSON shape")
	return fb

# ------------------------------------------------------------ transport
func chat_json(system: String, user: String, json_mode := true) -> Dictionary:
	if api_key == "" and provider != "ollama":
		return {"ok": false, "error": "No API key set (Settings, or env %s)" % PRESETS[provider]["env"]}
	var url := base_url.rstrip("/") + "/chat/completions"
	var body := {
		"model": model, "temperature": 0.8, "stream": false,
		"messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
	}
	if json_mode: body["response_format"] = {"type": "json_object"}
	# GLM models reason by default (~10 s per call). Contract nodes need fast, short
	# in-character replies, so switch thinking off (~2 s) on Zhipu / Z.ai endpoints.
	if "z.ai" in base_url or "bigmodel.cn" in base_url: body["thinking"] = {"type": "disabled"}
	var headers := PackedStringArray(["Content-Type: application/json"])
	if api_key != "": headers.append("Authorization: Bearer " + api_key)
	var http := HTTPRequest.new()
	http.timeout = timeout_sec
	add_child(http)
	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "request failed to start (%d)" % err}
	var out: Array = await http.request_completed
	http.queue_free()
	var result: int = out[0]
	var code: int = out[1]
	var text: String = (out[3] as PackedByteArray).get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS:
		last_error = "network error (result %d)" % result
		return {"ok": false, "error": last_error}
	if code == 400 and json_mode:
		return await chat_json(system, user, false) # provider may not support response_format
	if code < 200 or code >= 300:
		last_error = "HTTP %d: %s" % [code, text.left(200)]
		return {"ok": false, "error": last_error}
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary) or not parsed.has("choices") or parsed["choices"].is_empty():
		return {"ok": false, "error": "unexpected response: " + text.left(200)}
	var content: String = str(parsed["choices"][0].get("message", {}).get("content", ""))
	var data = extract_json(content)
	if data == null:
		last_error = "model did not return JSON: " + content.left(160)
		return {"ok": false, "error": last_error}
	last_error = ""
	return {"ok": true, "data": data, "raw": content}

## Tolerates ```json fences and chatter around the object.
static func extract_json(content: String) -> Variant:
	var s := content.strip_edges()
	var a := s.find("{")
	var b := s.rfind("}")
	if a < 0 or b <= a: return null
	return JSON.parse_string(s.substr(a, b - a + 1))

func test_connection() -> String:
	var res := await chat_json("Reply with JSON only.", "Return {\"ok\": true, \"tribe\": \"<one word name for a prehistoric tribe>\"}")
	if res["ok"]: return "Connected: " + JSON.stringify(res["data"])
	return "Failed: " + str(res.get("error", "?"))

func _count_call() -> void:
	if sim:
		sim.llm_calls += 1
		sim.ticks_since_llm = 0

static func _strip_private(bp: Dictionary) -> Dictionary:
	var o := {}
	for k in bp:
		if not str(k).begins_with("_"): o[k] = bp[k]
	return o
