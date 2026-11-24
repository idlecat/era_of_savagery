## Offline persona engine: a deterministic stand-in for the LLM node, so the game
## runs with no API key. Produces the same JSON shape a cloud model is asked for.
extends RefCounted

const D = preload("res://scripts/data.gd")
const I = preload("res://scripts/i18n.gd")

const DEFAULTS := {
	"cautious": {"cap": 6, "crew": 3, "focus": "fishery_and_defense", "wood_frac": 0.7, "aborts": ["enemy_attack", "hp_below_50%", "natural_disaster"]},
	"warrior":  {"cap": 10, "crew": 3, "focus": "hunting", "wood_frac": 0.4, "aborts": ["enemy_attack", "hp_below_20%"]},
	"mystic":   {"cap": 6, "crew": 3, "focus": "spiritual", "wood_frac": 0.6, "aborts": ["enemy_attack", "hp_below_40%", "natural_disaster"]},
	"agrarian": {"cap": 8, "crew": 4, "focus": "fishery", "wood_frac": 0.6, "aborts": ["enemy_attack", "hp_below_40%", "natural_disaster"]},
	"lazy":     {"cap": 4, "crew": 2, "focus": "balanced", "wood_frac": 0.5, "aborts": ["enemy_attack", "hp_below_50%"]},
}
const OPEN := {
	"cautious": "Great Chieftain, ", "warrior": "Ha! ", "mystic": "The spirits stir, Great Chieftain. ",
	"agrarian": "Chieftain! ", "lazy": "*yawns* Chieftain... ",
}
const LESSON := {
	"cautious": "to respect what lurks unseen", "warrior": "that beasts fear a bold spear",
	"mystic": "that the spirits watch over that shore", "agrarian": "that full bellies win more fights than spears",
	"lazy": "never to do twice what can be done once",
}
const CLOSE := {
	"cautious": "Does that sound wise?", "warrior": "If any beast comes, we crush it!",
	"mystic": "Shall I read the omens and begin?", "agrarian": "Full bellies, safe huts - agreed?",
	"lazy": "That's plenty, right?",
}
const NUM := ["no one", "one", "two", "three", "four", "five"]

## ctx: {arch, leader:{...profile}, env, terms:{crew_size,capacity_target,focus}, terms_set:bool,
##       player_message:String, previous:Dictionary, has_farming:bool, max_crew:int}
static func propose(ctx: Dictionary) -> Dictionary:
	var r := _propose(ctx)
	var ob: Dictionary = ctx.get("objection", {})
	if not ob.is_empty() and ctx.get("history", []).is_empty() and r.get("speech") is String: # a word about the tribe's ways first
		r["speech"] = I.t("%s Chieftain, about %s: I would have us choose %s.") % [ob["your_complaint"], ob["way"], ob["you_want"]] + " " + r["speech"]
	return r

static func _propose(ctx: Dictionary) -> Dictionary:
	if ctx.get("kind", "settle") == "research": return propose_research(ctx)
	if ctx.get("kind", "settle") == "war": return propose_war(ctx)
	if ctx.get("kind", "settle") == "seek": return propose_seek(ctx)
	var arch: String = ctx["arch"]
	var df: Dictionary = DEFAULTS.get(arch, DEFAULTS["cautious"])
	var prev: Dictionary = ctx.get("previous", {})
	var cap: int = prev.get("capacity_target", df["cap"])
	var crew: int = prev.get("crew_size", df["crew"])
	var focus: String = prev.get("focus", df["focus"])
	var flags := {"no_wall": prev.get("_no_wall", false), "fast": prev.get("_fast", false)}
	var reply := ""

	if ctx.get("terms_set", false):
		var t: Dictionary = ctx["terms"]
		cap = t.get("capacity_target", cap)
		crew = t.get("crew_size", crew)
		focus = t.get("focus", focus)

	var msg: String = str(ctx.get("player_message", "")).to_lower()
	if msg != "":
		var r := _apply_message(arch, msg, cap, crew, focus, flags)
		cap = r["cap"]; crew = r["crew"]; focus = r["focus"]; reply = r["reply"]
	elif ctx.get("terms_set", false) and not prev.is_empty():
		reply = {"cautious": I.t("As you command - I have adjusted the plan to your terms."),
			"warrior": I.t("Your terms, Chieftain? Fine - I'll make it work!"),
			"mystic": I.t("The omens bend to your will. I have reshaped the plan."),
			"agrarian": I.t("Your terms, then - but I'm keeping a full larder."),
			"lazy": I.t("Mm. Changed it. Happy?")}[arch]

	var river_known: bool = ctx.get("env", {}).get("river_known", true) # no dock on water no one has seen
	if focus == "farming" and not ctx.get("has_farming", false):
		focus = "fishery" if river_known else "balanced"
		reply += I.t(" We know nothing of farming yet - the river's fish will have to do.") if ctx.get("env", {}).get("river_known", true) else I.t(" We know nothing of farming yet - we will live by what we catch.")
	if not river_known: focus = {"fishery": "balanced", "fishery_and_defense": "defense"}.get(focus, focus)
	crew = clampi(crew, 1, ctx.get("max_crew", 5))
	cap = clampi(cap, 2, 15)

	var bp := _build_plan(arch, cap, crew, focus, flags, df)
	bp["_no_wall"] = flags["no_wall"]
	bp["_fast"] = flags["fast"]
	var speech := _speech(arch, ctx, bp, reply)
	return {"speech": speech, "blueprint": bp}

static func _apply_message(arch: String, msg: String, cap: int, crew: int, focus: String, flags: Dictionary) -> Dictionary:
	var reply := ""
	var re_num := RegEx.create_from_string("(\\d+)\\s*(people|souls|mouths|capacity|folk|人|口)")
	var m := re_num.search(msg)
	if m: cap = int(m.get_string(1))
	elif _any(msg, ["bigger", "larger", "more people", "expand", "grand", "大一点", "更大", "扩大", "多住", "更多人"]): cap += 3
	elif _any(msg, ["smaller", "fewer", "modest", "small", "小一点", "更小", "少一点"]): cap = maxi(2, cap - 2)
	var re_crew := RegEx.create_from_string("(\\d+)\\s*(helpers|crew|hands|brothers|workers|men|women|个帮手|个人手|名帮手)")
	var mc := re_crew.search(msg)
	if mc: crew = int(mc.get_string(1)) + (0 if "crew" in mc.get_string(2) else 1)

	if _any(msg, ["no wall", "skip the wall", "skip the palisade", "without a palisade", "forget the wall", "no palisade", "不要墙", "不建墙", "别建墙", "不要围墙", "不要栅栏", "不用墙"]):
		if arch == "cautious":
			reply = I.t("Chieftain, I cannot in good conscience leave us without a palisade - not with those tracks. I'll keep it, but small and quick.")
		else:
			flags["no_wall"] = true
			reply = I.t("No walls, then.") if arch != "warrior" else I.t("Walls are for cowards anyway!")
	elif _any(msg, ["wall", "palisade", "defen", "safe", "protect", "墙", "栅栏", "防御", "安全", "保护"]):
		flags["no_wall"] = false
		focus = "fishery_and_defense" if focus in ["fishery", "fishery_and_defense"] else "defense"
		reply = {"warrior": I.t("Walls! Fine, Chieftain - but the weapon rack stays."), "cautious": I.t("Wise. Safety first, always."),
			"mystic": I.t("A ring of stakes and a ring of spirits, then."), "agrarian": I.t("Walls keep beasts from the larder. Good."), "lazy": I.t("Walls... more work. Fine.")}[arch]
	if _any(msg, ["fish", "dock", "鱼", "码头"]): focus = "fishery"
	if _any(msg, ["farm", "crop", "field", "农", "种地", "田"]): focus = "farming"
	if _any(msg, ["hunt", "meat", "狩猎", "打猎", "肉"]): focus = "hunting"
	if _any(msg, ["spirit", "totem", "shrine", "ritual", "bless", "神", "图腾", "祭", "仪式", "祝福"]): focus = "spiritual"
	if _any(msg, ["fast", "quick", "hurry", "now", "快", "赶紧", "马上"]):
		flags["fast"] = true
		crew += 1
		reply += " " + {"cautious": I.t("Haste makes mistakes... but I'll bring another pair of hands."), "warrior": I.t("Fast is how I like it!"),
			"mystic": I.t("The spirits dislike haste, but I hear you."), "agrarian": I.t("Quick, but we eat first."), "lazy": I.t("Fast?! ...I'll bring someone else to do it.")}[arch]
	if reply == "":
		reply = {"cautious": I.t("I hear you, Chieftain. Let me rethink it."), "warrior": I.t("Hah, I like how you think!"),
			"mystic": I.t("Your words ripple through the plan."), "agrarian": I.t("Hmm, yes, I'll change it."), "lazy": I.t("Okay, okay.")}[arch]
	if arch == "cautious" and cap > 8: reply += I.t(" So many mouths over there worries me - we raise the palisade before anything else.")
	return {"cap": cap, "crew": crew, "focus": focus, "reply": reply.strip_edges()}

static func _num(n: int) -> String:
	return I.t(NUM[n]) if n < NUM.size() else str(n)

static func _any(s: String, words: Array) -> bool:
	for w in words:
		if w in s: return true
	return false

static func _build_plan(arch: String, cap: int, crew: int, focus: String, flags: Dictionary, df: Dictionary) -> Dictionary:
	var hut := "large_hut" if arch == "warrior" or cap >= 12 else "hut"
	var per: int = D.STRUCTURES[hut]["cap"]
	var huts := clampi(ceili(float(cap) / per), 1, 4)
	var focus_steps: Array = []
	match focus:
		"defense": focus_steps = [_b("palisade")]
		"fishery": focus_steps = [_b("fishing_dock")]
		"fishery_and_defense": focus_steps = [_b("palisade"), _b("fishing_dock")]
		"farming": focus_steps = [_b("farm_plot")]
		"hunting": focus_steps = [_b("weapon_rack"), {"action": "gather_food", "target_amount": 25}]
		"spiritual": focus_steps = [_b("totem_shrine")]
		_: focus_steps = [_b("bonfire")]
	var steps: Array = []
	match arch:
		"cautious":
			steps = [_b("palisade")] + focus_steps + [_b(hut, huts)]
		"warrior":
			steps = [_b("bonfire"), _b("weapon_rack"), _b(hut, huts)] + focus_steps
		"mystic":
			steps = [{"action": "ritual", "duration_sec": 12}, _b("totem_shrine"), _b(hut, huts)] + focus_steps + [_b("bonfire")]
		"agrarian":
			steps = [{"action": "gather_food", "target_amount": 20}] + focus_steps + [_b(hut, huts)]
		"lazy":
			steps = [_b(hut, huts), _b("bonfire")]
	# de-duplicate single structures, honor "no walls"
	var seen := {}
	var clean: Array = []
	for s in steps:
		var k: String = s["action"] + str(s.get("structure", ""))
		if seen.has(k): continue
		if flags.get("no_wall", false) and s.get("structure", "") == "palisade" and arch != "cautious": continue
		seen[k] = true
		clean.append(s)
	var wood := 0
	for s in clean:
		if s["action"] == "build": wood += D.STRUCTURES[s["structure"]]["wood"] * s["count"]
	var frac: float = df["wood_frac"] * (0.5 if flags.get("fast", false) else 1.0)
	var gather := maxi(20, int(round(wood * frac / 10.0)) * 10)
	var insert_at := 1 if arch in ["mystic", "agrarian"] else 0
	clean.insert(insert_at, {"action": "gather_wood", "target_amount": gather, "location": "nearby_forest"})
	return {
		"plan_id": "frontier_%s" % {"cautious": "stockade", "warrior": "warcamp", "mystic": "sanctum", "agrarian": "larder", "lazy": "camp"}[arch],
		"crew_size": crew, "capacity_target": cap, "focus": focus, "steps": clean,
		"abort_conditions": df["aborts"].duplicate(),
	}

static func _b(structure: String, count := 1) -> Dictionary:
	return {"action": "build", "structure": structure, "count": count}

static func _phrase(arch: String, s: Dictionary) -> String:
	match s["action"]:
		"gather_wood": return I.t("fell %d wood") % s["target_amount"] if arch != "warrior" else I.t("grab a little timber")
		"gather_food": return I.t("stock up on meat and berries") if arch != "warrior" else I.t("hunt whatever moves")
		"ritual": return I.t("cleanse the ground with a ritual")
		"build":
			var st: String = s["structure"]
			var n: int = s["count"]
			match st:
				"palisade": return I.t("raise a wooden palisade for safety") if arch == "cautious" else I.t("put up a palisade")
				"bonfire": return I.t("light a grand bonfire") if arch == "warrior" else I.t("light a bonfire")
				"weapon_rack": return I.t("put a weapon rack right in the center")
				"fishing_dock": return I.t("build a fishing dock")
				"totem_shrine": return I.t("raise a totem shrine")
				"farm_plot": return I.t("clear a farm plot")
				"granary": return I.t("raise a granary")
				"hut": return I.t("build %s hut%s") % [_num(n), I.plural_s() if n > 1 else ""]
				"large_hut": return I.t("build %s large hut%s") % [_num(n), I.plural_s() if n > 1 else ""]
	return s["action"]

static func _speech(arch: String, ctx: Dictionary, bp: Dictionary, reply: String) -> String:
	var leader: Dictionary = ctx["leader"]
	var parts: Array = []
	if reply != "":
		parts.append(reply)
	else:
		var env: Dictionary = ctx.get("env", {})
		var timber: String = env.get("timber", I.t("fine timber"))
		var obs: String = {
			"cautious": I.t("the new land has %s, but there are beast tracks in the tall grass.") % timber,
			"warrior": I.t("Beast tracks out there? Good. Let them come."),
			"mystic": I.t("Tracks of the great cat mark that land - yet the land there is sacred."),
			"agrarian": I.t("the new land has berries, and the game there is thick."),
			"lazy": I.t("that land... it's far. And there are tracks. Big ones."),
		}[arch]
		if not env.get("explored", true): obs = I.t("no one has walked that land yet - we go into the unknown.")
		parts.append(I.t(OPEN[arch]) + obs)
		var mem: Array = leader.get("memory_stream", [])
		if not mem.is_empty():
			var m: String = mem[mem.size() - 1] if arch == "lazy" else _best_memory(ctx)
			parts.append(I.t("I have not forgotten the day I %s - it taught me %s.") % [m, I.t(LESSON[arch])])
	var helpers: int = bp["crew_size"] - 1
	var who: String = (I.t("%s brothers") if arch == "warrior" else (I.t("%s helper") if helpers == 1 else I.t("%s helpers"))) % _num(helpers)
	var acts: Array = []
	for s in bp["steps"]: acts.append(_phrase(arch, s))
	var seq: String = acts[0]
	if acts.size() > 1: seq = I.t(", then ").join(acts.slice(0, acts.size() - 1)) + I.t(", and finally ") + acts[acts.size() - 1]
	var lead := I.t("Forget slow walls - ") if arch == "warrior" and not _has_struct(bp, "palisade") else ""
	if arch == "cautious": lead = I.t("I suggest we start carefully: ")
	parts.append(I.t("%sI'll take %s out there: first %s - room for %d people.") % [lead, who if helpers > 0 else I.t("only myself"), seq, bp["capacity_target"]])
	parts.append(I.t(CLOSE[arch]))
	return ("" if I.is_zh() else " ").join(parts)

static func _best_memory(ctx: Dictionary) -> String:
	# memory_stream is chronological text ("Day N: ..."); the profile also exposes the raw list
	var mem: Array = ctx["leader"].get("memory_stream", [])
	var best: String = ctx.get("top_memory", "")
	if best != "": return best
	var line: String = mem[0]
	return line.split(": ", true, 1)[1] if ": " in line else line

static func _has_struct(bp: Dictionary, st: String) -> bool:
	for s in bp["steps"]:
		if s.get("structure", "") == st: return true
	return false

# ------------------------------------------------------------ research contracts
## Which ideas each temperament is drawn to, most wanted first.
const RESEARCH_TASTE := {
	"cautious": ["tools", "hide", "pottery", "code", "fire", "farming", "domestication", "bronze", "totems"],
	"warrior": ["tools", "bronze", "domestication", "hide", "fire", "code", "farming", "pottery", "totems"],
	"mystic": ["fire", "totems", "pottery", "hide", "farming", "code", "tools", "domestication", "bronze"],
	"agrarian": ["farming", "pottery", "domestication", "fire", "tools", "hide", "code", "totems", "bronze"],
	"lazy": [], # whatever is closest to done
}
const RESEARCH_WHY := {
	"cautious": "It keeps people alive, and that is all I ask of an idea.",
	"warrior": "Anything that makes the spear bite harder is worth sweat.",
	"mystic": "The spirits have whispered of it in the smoke.",
	"agrarian": "A full belly is the beginning of every good thing.",
	"lazy": "It's nearly figured out already. Less work.",
}

static func propose_research(ctx: Dictionary) -> Dictionary:
	var arch: String = ctx["arch"]
	var cands: Array = ctx.get("candidates", [])
	var prev: Dictionary = ctx.get("previous", {})
	var t: Dictionary = ctx.get("terms", {}) if ctx.get("terms_set", false) else {}
	if cands.is_empty():
		return {"speech": I.t("Chieftain, I can think of nothing new to seek. We must live more before new wisdom comes."), "blueprint": {}}
	var ids: Array = cands.map(func(c): return c["id"])
	var pick: String = ""
	var msg: String = str(ctx.get("player_message", "")).to_lower()
	for c in cands: # the Chieftain names an idea
		if c["id"] in msg or c["name"].to_lower() in msg or c["name"].to_lower().split(" ")[-1] in msg: pick = c["id"]
	if pick == "" and t.get("tech", "") in ids: pick = t["tech"]
	if pick == "" and prev.get("tech", "") in ids: pick = prev["tech"]
	if pick == "":
		if arch == "lazy":
			var best: Dictionary = cands[0]
			for c in cands:
				if c["insight_pct"] > best["insight_pct"]: best = c
			pick = best["id"]
		else:
			for id in RESEARCH_TASTE[arch]:
				if id in ids:
					pick = id
					break
	var cand: Dictionary = cands[ids.find(pick)]
	var crew: int = clampi(t.get("crew_size", prev.get("crew_size", 2 if arch != "lazy" else 1)), 1, ctx.get("max_crew", 4))
	var fast: bool = _any(msg, ["fast", "quick", "hurry", "快", "赶紧"])
	var exp_len: int = {"cautious": 30, "warrior": 15, "mystic": 20, "agrarian": 22, "lazy": 12}[arch]
	if fast: exp_len = maxi(8, exp_len - 8)
	var steps: Array = []
	var mat := "gather_stone" if ctx.get("env", {}).get("stone_quarrying_possible", false) and pick in ["bronze", "tools", "totems", "code"] else "gather_wood"
	match arch:
		"mystic": steps = [{"action": "ritual", "duration_sec": 10}, {"action": mat, "target_amount": 15}, {"action": "experiment", "duration_sec": exp_len}]
		"cautious": steps = [{"action": mat, "target_amount": 25}, {"action": "experiment", "duration_sec": exp_len}, {"action": "experiment", "duration_sec": 10}]
		"agrarian": steps = [{"action": "gather_food", "target_amount": 20}, {"action": "experiment", "duration_sec": exp_len}]
		"warrior": steps = [{"action": mat, "target_amount": 15}, {"action": "experiment", "duration_sec": exp_len}]
		_: steps = [{"action": "experiment", "duration_sec": exp_len}]
	var bp := {"kind": "research", "plan_id": "seek_%s" % pick, "tech": pick, "crew_size": crew, "steps": steps,
		"abort_conditions": ["enemy_attack", "hp_below_30%"]}
	var opener: String = I.t(OPEN[arch])
	var reply := ""
	if msg != "":
		reply = I.t("As you wish - we chase %s. ") % cand["name"] if cand["name"].to_lower().split(" ")[-1] in msg or pick in msg else I.t("I hear you. ")
	var mem: Array = ctx["leader"].get("memory_stream", [])
	var memline := ""
	if not mem.is_empty() and reply == "":
		memline = I.t(" I have not forgotten the day I %s.") % _best_memory(ctx)
	var how: String = cand.get("learned_by", "")
	var speech := I.t("%s%sI would seek %s. %s%s We already understand %d%% of it from %s. Give me %s and %d breaths of trial and error.") % [
		opener, reply, cand["name"], I.t(RESEARCH_WHY[arch]), memline, cand["insight_pct"], how if how != "" else I.t("our daily work"),
		((I.t("%s helper") if crew == 2 else I.t("%s helpers")) % _num(crew - 1)) if crew > 1 else I.t("the quiet of the workshop"), exp_len]
	return {"speech": speech, "blueprint": bp}

## A war party: each personality picks its own objective and way of fighting.
static func propose_war(ctx: Dictionary) -> Dictionary:
	var arch: String = ctx["arch"]
	var env: Dictionary = ctx.get("env", {})
	var enemies: Array = env.get("enemies_known", [])
	if enemies.is_empty():
		return {"speech": I.t("Chieftain, we know of no clan to fight. Let the scouts find our neighbours first."), "blueprint": {}}
	var prev: Dictionary = ctx.get("previous", {})
	var t: Dictionary = ctx.get("terms", {}) if ctx.get("terms_set", false) else {}
	var target: String = t.get("target", prev.get("target", env.get("chieftain_suggests", "")))
	var foe: Dictionary = enemies[0]
	for e in enemies:
		if e["id"] == target: foe = e
	var obj: String = {"warrior": "burn", "cautious": "loot", "mystic": "break", "agrarian": "loot", "lazy": "loot"}[arch]
	obj = t.get("objective", prev.get("objective", obj))
	var msg: String = str(ctx.get("player_message", "")).to_lower()
	var reply := ""
	if _any(msg, ["burn", "fire", "torch", "烧", "火"]): obj = "burn"
	elif _any(msg, ["food", "loot", "plunder", "steal", "抢", "粮", "食物"]): obj = "loot"
	elif _any(msg, ["warrior", "break", "kill", "crush", "战士", "击溃", "杀"]): obj = "break"
	var crew: int = clampi(t.get("crew_size", prev.get("crew_size", {"warrior": 6, "cautious": 5, "mystic": 4, "agrarian": 4, "lazy": 3}[arch])), 2, ctx.get("max_crew", 6))
	var scout: bool = arch in ["cautious", "mystic"] or _any(msg, ["scout", "watch", "careful", "侦察", "小心"])
	if _any(msg, ["no scout", "fast", "quick", "now", "快", "立刻"]): scout = false
	var steps: Array = []
	if arch in ["warrior", "mystic"]: steps.append({"action": "war_dance", "duration_sec": 6 if arch == "warrior" else 12})
	if scout: steps.append({"action": "scout", "duration_sec": 15 if arch == "cautious" else 8})
	steps += [{"action": "assault"}, {"action": obj, "duration_sec": 10}, {"action": "return"}]
	var aborts: Array = ["heavy_losses"]
	if arch == "cautious": aborts.append("hp_below_50%")
	elif arch != "warrior": aborts.append("hp_below_30%")
	var bp := {"kind": "war", "plan_id": "%s_raid_%s" % [obj, foe["id"]], "target": foe["id"], "objective": obj, "crew_size": crew, "steps": steps, "abort_conditions": aborts}
	if msg != "": reply = I.t("So be it. ")
	var goal: String = {"loot": I.t("we take their food and timber"), "burn": I.t("we burn their huts"), "break": I.t("we break their warriors")}[obj]
	var speech: String = {
		"warrior": I.t("%sAt last! The %s have grown fat and proud. Give me %d spears, we dance, we strike, and %s!") % [reply, foe["name"], crew, goal],
		"cautious": I.t("%sIf it must be the %s, we do it carefully: we watch their village first, strike with %d of us, %s, and come home before they gather. We stop if blood runs too freely.") % [reply, foe["name"], crew, goal],
		"mystic": I.t("%sThe spirits demand it. We dance for the ancestors, then %d of us fall upon the %s and %s.") % [reply, crew, foe["name"], goal],
		"agrarian": I.t("%sThe %s's stores would fill our bellies through winter. %d of us, quick and quiet - %s.") % [reply, foe["name"], crew, goal],
		"lazy": I.t("%sA long walk to the %s... fine. %d of us, %s, and home again.") % [reply, foe["name"], crew, goal],
	}[arch]
	var mem: Array = ctx["leader"].get("memory_stream", [])
	if not mem.is_empty(): speech += I.t(" I have not forgotten the day I %s.") % _best_memory(ctx)
	return {"speech": speech, "blueprint": bp}

## ctx: {arch, name, summary:{...}, allowed:Array}
static func emergency(ctx: Dictionary) -> Dictionary:
	var arch: String = ctx["arch"]
	var sm: Dictionary = ctx["summary"]
	var reason: String = sm["reason"]
	var pct: int = sm["progress_pct"]
	var built := ", ".join(sm["built"]) if not sm["built"].is_empty() else I.t("nothing yet")
	var half := ", ".join(sm["half_built"]) if not sm["half_built"].is_empty() else I.t("nothing")
	var speech := ""
	var opts: Array = []
	match reason:
		"enemy_attack":
			speech = {
				"cautious": I.t("Chieftain! What I feared - %s burst from the tall grass! We are %d%% done: %s standing, %s half-raised. We must not throw lives away.") % [sm["threat"], pct, built, half],
				"warrior": I.t("THEY CAME! %s, just as I hoped! We're %d%% done - %s up, %s half-built. Let me show them what a spear is for!") % [sm["threat"], pct, built, half],
				"mystic": I.t("The heron screamed - %s stalk our camp! We are %d%% done. The totem's power could turn them away, if the tribe's lore allows.") % [sm["threat"], pct],
				"agrarian": I.t("Chieftain, %s! They smell our meat! We're %d%% done - %s standing. What do we do?") % [sm["threat"], pct, built],
				"lazy": I.t("Uh. Chieftain. %s. Right here. We're %d%% done, which is... something. Can we go home?") % [sm["threat"], pct],
			}[arch]
			opts = {
				"cautious": [["reinforce", I.t("Hold the half-built camp and wait for reinforcements")], ["retreat", I.t("Abandon the timber and fall back to the village")], ["hold", I.t("Stand behind what we have built and fight")]],
				"warrior": [["hold", I.t("Stand and fight - we crush them!")], ["reinforce", I.t("Send more spears and we finish them faster")], ["retreat", I.t("...Fall back, if you must insist")]],
				"mystic": [["ward", I.t("Invoke the totem ward to drive them off (%d lore)") % int(ctx.get("ward_cost", 10))], ["hold", I.t("Fight with the spirits at our backs")], ["retreat", I.t("Fall back to the village")]],
				"agrarian": [["reinforce", I.t("Send help - we guard the larder")], ["hold", I.t("Fight for our supplies")], ["retreat", I.t("Run, and take what food we can")]],
				"lazy": [["retreat", I.t("Go home. Please.")], ["reinforce", I.t("Send someone else to deal with them")], ["hold", I.t("Fine, we fight")]],
			}[arch]
		"leader_wounded":
			speech = {
				"warrior": I.t("Bah! A scratch - %s HP left. I've had worse from a cave bear. Let me keep going!") % sm["leader_hp"],
				"cautious": I.t("Chieftain... I am hurt badly (%s HP). The work is %d%% done. A dead builder raises no huts.") % [sm["leader_hp"], pct],
			}.get(arch, I.t("Chieftain, I am wounded (%s HP) and the work is only %d%% done.") % [sm["leader_hp"], pct])
			opts = [["rest", I.t("Let me return to the bonfire; the crew carries on")], ["press_on", I.t("I'll bind the wound and keep working")], ["retreat", I.t("Abandon the contract")]]
			if arch == "warrior": opts = [opts[1], opts[0], opts[2]]
		"heavy_losses":
			speech = {
				"warrior": I.t("They fight like cornered bears, Chieftain! Half our spears are down - but %s still stand. One more push!") % sm["threat"],
				"cautious": I.t("Chieftain, half our war party is down. %s still hold the village. We should not throw away the rest.") % sm["threat"],
			}.get(arch, I.t("Chieftain, we have lost half our war party! %s still stand against us.") % sm["threat"])
			opts = [["retreat", I.t("Fall back and bring the living home")], ["reinforce", I.t("Send fresh fighters from the village")], ["press_on", I.t("Fight on to the end")]]
			if arch == "warrior": opts = [opts[2], opts[1], opts[0]]
		"natural_disaster":
			speech = I.t("Chieftain, the waters rise over the camp! We are %d%% done - %s may be lost.") % [pct, half]
			match sm.get("disaster", ""):
				"blizzard": speech = I.t("Chieftain, a blizzard buries the camp! We are %d%% done, but no one can work in this cold.") % pct
				"wildfire": speech = I.t("Chieftain, the forest is burning around the camp! We are %d%% done - %s may be lost.") % [pct, half]
				"eruption": speech = I.t("Chieftain, the Fire Mountain spits fire and ash over us! We are %d%% done - %s may be lost.") % [pct, half]
				"earthquake": speech = I.t("Chieftain, the earth shook and our work fell down! We are %d%% done - %s may be lost.") % [pct, half]
			opts = [["shelter", I.t("Shelter on high ground until the waters fall")], ["retreat", I.t("Abandon the camp and save ourselves")]]
		_:
			speech = I.t("Chieftain, something has gone wrong.")
			opts = [["hold", "Hold"], ["retreat", "Retreat"]]
	var allowed: Array = ctx.get("allowed", [])
	var options: Array = []
	for o in opts:
		if allowed.is_empty() or o[0] in allowed: options.append({"effect": o[0], "label": o[1]})
	return {"speech": speech, "options": options}

# ------------------------------------------------------------ search quests (kind "seek")
## What each temperament looks for when the Chieftain leaves it to them.
const SEEK_TASTE := {"agrarian": "food", "mystic": "medicine", "warrior": "ore", "cautious": "food", "lazy": "food"}

static func propose_seek(ctx: Dictionary) -> Dictionary:
	var arch: String = ctx["arch"]
	var env: Dictionary = ctx.get("env", {})
	var places: Array = env.get("places_you_could_search", [])
	var t: Dictionary = ctx.get("terms", {}) if ctx.get("terms_set", false) else {}
	var prev: Dictionary = ctx.get("previous", {})
	var msg: String = str(ctx.get("player_message", "")).to_lower()
	var group: String = str(t.get("group", ctx.get("seek_group", SEEK_TASTE.get(arch, "food"))))
	if group == "": group = SEEK_TASTE.get(arch, "food")
	if places.is_empty():
		return {"speech": I.t("Chieftain, I know of nowhere to look for that."), "blueprint": {}}
	# where: the cautious stay near, the bold go far, the devout to the hills and the fire mountain
	# (places combed lately are left alone while fresh ones remain: they come last in the list)
	var fresh: Array = places.filter(func(p):
		var w = p.get("we_searched_here", {})
		return not (w is Dictionary and not w.is_empty()))
	if fresh.is_empty(): fresh = places
	var near: int = fresh[0]["index"]
	var far: int = fresh.back()["index"]
	var pick := near
	match arch:
		"warrior": pick = far
		"mystic":
			for p in fresh:
				if not p.get("seen_before", true): pick = p["index"]
	var told: String = str(env.get("the_elders_remember", {}).get("grows_in", ""))
	if told != "": # where the elders say it grows
		for p in fresh:
			if p.get("kind", "") == told:
				pick = p["index"]
				break
	if _any(msg, ["far", "farther", "远"]): pick = far
	if _any(msg, ["near", "close", "近"]): pick = near
	var dr: Array = env.get("days_you_may_search", [1, 3])
	var days: int = {"cautious": 1, "lazy": 1, "warrior": 2, "mystic": 2, "agrarian": 2}.get(arch, 2)
	if _any(msg, ["long", "longer", "more days", "久", "多几天"]): days = int(dr[1])
	if _any(msg, ["quick", "short", "fast", "快", "短"]): days = int(dr[0])
	days = clampi(int(prev.get("days", days)) if msg == "" and not prev.is_empty() else days, int(dr[0]), int(dr[1]))
	var crew: int = clampi(t.get("crew_size", prev.get("crew_size", 2 if arch != "lazy" else 1)), 1, ctx.get("max_crew", 4))
	var place: String = places[pick]["place"]
	var what: String = I.t({"food": "new foods", "medicine": "healing plants", "ore": "stones and ores"}[group])
	var line: String = {
		"cautious": "Great Chieftain, we will look for %s in %s, close enough to come home before dark: %d day%s, no more.",
		"warrior": "Ha! %s? Then we go far, to %s, where no one has looked: %d day%s of hunting for them!",
		"mystic": "The spirits hide %s in %s. Give us %d day%s; we will listen to the ground.",
		"agrarian": "Something new to eat, Chieftain! Let us look for %s in %s for %d day%s.",
		"lazy": "*yawns* Mm. %s, then. In %s, not far. %d day%s.",
	}.get(arch, "Great Chieftain, we will look for %s in %s, close enough to come home before dark: %d day%s, no more.")
	var speech: String = I.t(line) % [what, place, days, I.plural_s() if days > 1 else ""]
	return {"speech": speech,
		"blueprint": {"kind": "seek", "plan_id": "search_%s" % group, "group": group, "place": places[pick]["index"], "days": days, "crew_size": crew}}
