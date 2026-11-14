## Offline persona engine: a deterministic stand-in for the LLM node, so the POC
## runs with no API key. Produces the same JSON shape a cloud model is asked for.
extends RefCounted

const D = preload("res://scripts/data.gd")

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
		reply = {"cautious": "As you command - I have adjusted the plan to your terms.",
			"warrior": "Your terms, Chieftain? Fine - I'll make it work!",
			"mystic": "The omens bend to your will. I have reshaped the plan.",
			"agrarian": "Your terms, then - but I'm keeping a full larder.",
			"lazy": "Mm. Changed it. Happy?"}[arch]

	if focus == "farming" and not ctx.get("has_farming", false):
		focus = "fishery"
		reply += " We know nothing of farming yet - the river's fish will have to do."
	crew = clampi(crew, 1, ctx.get("max_crew", 5))
	cap = clampi(cap, 2, 15)

	var bp := _build_plan(arch, cap, crew, focus, flags, df)
	bp["_no_wall"] = flags["no_wall"]
	bp["_fast"] = flags["fast"]
	var speech := _speech(arch, ctx, bp, reply)
	return {"speech": speech, "blueprint": bp}

static func _apply_message(arch: String, msg: String, cap: int, crew: int, focus: String, flags: Dictionary) -> Dictionary:
	var reply := ""
	var re_num := RegEx.create_from_string("(\\d+)\\s*(people|souls|mouths|capacity|folk)")
	var m := re_num.search(msg)
	if m: cap = int(m.get_string(1))
	elif _any(msg, ["bigger", "larger", "more people", "expand", "grand"]): cap += 3
	elif _any(msg, ["smaller", "fewer", "modest", "small"]): cap = maxi(2, cap - 2)
	var re_crew := RegEx.create_from_string("(\\d+)\\s*(helpers|crew|hands|brothers|workers|men|women)")
	var mc := re_crew.search(msg)
	if mc: crew = int(mc.get_string(1)) + (0 if "crew" in mc.get_string(2) else 1)

	if _any(msg, ["no wall", "skip the wall", "skip the palisade", "without a palisade", "forget the wall", "no palisade"]):
		if arch == "cautious":
			reply = "Chieftain, I cannot in good conscience leave us without a palisade - not with those tracks. I'll keep it, but small and quick."
		else:
			flags["no_wall"] = true
			reply = "No walls, then." if arch != "warrior" else "Walls are for cowards anyway!"
	elif _any(msg, ["wall", "palisade", "defen", "safe", "protect"]):
		flags["no_wall"] = false
		focus = "fishery_and_defense" if focus in ["fishery", "fishery_and_defense"] else "defense"
		reply = {"warrior": "Walls! Fine, Chieftain - but the weapon rack stays.", "cautious": "Wise. Safety first, always.",
			"mystic": "A ring of stakes and a ring of spirits, then.", "agrarian": "Walls keep beasts from the larder. Good.", "lazy": "Walls... more work. Fine."}[arch]
	if _any(msg, ["fish", "dock"]): focus = "fishery"
	if _any(msg, ["farm", "crop", "field"]): focus = "farming"
	if _any(msg, ["hunt", "meat"]): focus = "hunting"
	if _any(msg, ["spirit", "totem", "shrine", "ritual", "bless"]): focus = "spiritual"
	if _any(msg, ["fast", "quick", "hurry", "now"]):
		flags["fast"] = true
		crew += 1
		reply += " " + {"cautious": "Haste makes mistakes... but I'll bring another pair of hands.", "warrior": "Fast is how I like it!",
			"mystic": "The spirits dislike haste, but I hear you.", "agrarian": "Quick, but we eat first.", "lazy": "Fast?! ...I'll bring someone else to do it."}[arch]
	if reply == "":
		reply = {"cautious": "I hear you, Chieftain. Let me rethink it.", "warrior": "Hah, I like how you think!",
			"mystic": "Your words ripple through the plan.", "agrarian": "Hmm, yes, I'll change it.", "lazy": "Okay, okay."}[arch]
	if arch == "cautious" and cap > 8: reply += " So many mouths over there worries me - we raise the palisade before anything else."
	return {"cap": cap, "crew": crew, "focus": focus, "reply": reply.strip_edges()}

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
	clean.insert(insert_at, {"action": "gather_wood", "target_amount": gather, "location": "east_forest"})
	return {
		"plan_id": "east_river_outpost_%s" % {"cautious": "stockade", "warrior": "warcamp", "mystic": "sanctum", "agrarian": "larder", "lazy": "camp"}[arch],
		"crew_size": crew, "capacity_target": cap, "focus": focus, "steps": clean,
		"abort_conditions": df["aborts"].duplicate(),
	}

static func _b(structure: String, count := 1) -> Dictionary:
	return {"action": "build", "structure": structure, "count": count}

static func _phrase(arch: String, s: Dictionary) -> String:
	match s["action"]:
		"gather_wood": return "fell %d wood" % s["target_amount"] if arch != "warrior" else "grab a little timber"
		"gather_food": return "stock up on meat and berries" if arch != "warrior" else "hunt whatever moves"
		"ritual": return "cleanse the ground with a ritual"
		"build":
			var st: String = s["structure"]
			var n: int = s["count"]
			match st:
				"palisade": return "raise a wooden palisade for safety" if arch == "cautious" else "put up a palisade"
				"bonfire": return "light a grand bonfire" if arch == "warrior" else "light a bonfire"
				"weapon_rack": return "put a weapon rack right in the center"
				"fishing_dock": return "build a fishing dock"
				"totem_shrine": return "raise a totem shrine"
				"farm_plot": return "clear a farm plot"
				"hut": return "build %s hut%s" % [NUM[n] if n < NUM.size() else str(n), "s" if n > 1 else ""]
				"large_hut": return "build %s large hut%s" % [NUM[n] if n < NUM.size() else str(n), "s" if n > 1 else ""]
	return s["action"]

static func _speech(arch: String, ctx: Dictionary, bp: Dictionary, reply: String) -> String:
	var leader: Dictionary = ctx["leader"]
	var parts: Array = []
	if reply != "":
		parts.append(reply)
	else:
		var env: Dictionary = ctx.get("env", {})
		var timber: String = env.get("timber", "fine timber")
		var obs: String = {
			"cautious": "the east bank has %s, but there are beast tracks in the tall grass." % timber,
			"warrior": "Saber-tooth tracks on the east bank? Good. Let them come.",
			"mystic": "Tracks of the great cat mark the eastern shore - yet the land there is sacred.",
			"agrarian": "the east bank has berries, and the river there is thick with fish.",
			"lazy": "the east bank... it's far. And there are tracks. Big ones.",
		}[arch]
		parts.append(OPEN[arch] + obs)
		var mem: Array = leader.get("memory_stream", [])
		if not mem.is_empty():
			var m: String = mem[mem.size() - 1] if arch == "lazy" else _best_memory(ctx)
			parts.append("I have not forgotten the day I %s - it taught me %s." % [m, LESSON[arch]])
	var helpers: int = bp["crew_size"] - 1
	var who := "%s %s" % [NUM[helpers] if helpers < NUM.size() else str(helpers), "brothers" if arch == "warrior" else ("helper" if helpers == 1 else "helpers")]
	var acts: Array = []
	for s in bp["steps"]: acts.append(_phrase(arch, s))
	var seq: String = acts[0]
	if acts.size() > 1: seq = ", then ".join(acts.slice(0, acts.size() - 1)) + ", and finally " + acts[acts.size() - 1]
	var lead := "Forget slow walls - " if arch == "warrior" and not _has_struct(bp, "palisade") else ""
	if arch == "cautious": lead = "I suggest we start carefully: "
	parts.append("%sI'll take %s across: first %s - room for %d people." % [lead, who if helpers > 0 else "only myself", seq, bp["capacity_target"]])
	parts.append(CLOSE[arch])
	return " ".join(parts)

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

## ctx: {arch, name, summary:{...}, allowed:Array}
static func emergency(ctx: Dictionary) -> Dictionary:
	var arch: String = ctx["arch"]
	var sm: Dictionary = ctx["summary"]
	var reason: String = sm["reason"]
	var pct: int = sm["progress_pct"]
	var built := ", ".join(sm["built"]) if not sm["built"].is_empty() else "nothing yet"
	var half := ", ".join(sm["half_built"]) if not sm["half_built"].is_empty() else "nothing"
	var speech := ""
	var opts: Array = []
	match reason:
		"enemy_attack":
			speech = {
				"cautious": "Chieftain! What I feared - %s burst from the tall grass! We are %d%% done: %s standing, %s half-raised. We must not throw lives away." % [sm["threat"], pct, built, half],
				"warrior": "THEY CAME! %s, just as I hoped! We're %d%% done - %s up, %s half-built. Let me show them what a spear is for!" % [sm["threat"], pct, built, half],
				"mystic": "The heron screamed - %s stalk our camp! We are %d%% done. The totem's power could turn them away, if the tribe's lore allows." % [sm["threat"], pct],
				"agrarian": "Chieftain, %s! They smell our meat! We're %d%% done - %s standing. What do we do?" % [sm["threat"], pct, built],
				"lazy": "Uh. Chieftain. %s. Right here. We're %d%% done, which is... something. Can we go home?" % [sm["threat"], pct],
			}[arch]
			opts = {
				"cautious": [["reinforce", "Hold the half-built camp and wait for reinforcements"], ["retreat", "Abandon the timber and retreat across the river"], ["hold", "Stand behind what we have built and fight"]],
				"warrior": [["hold", "Stand and fight - we crush them!"], ["reinforce", "Send more spears and we finish them faster"], ["retreat", "...Fall back, if you must insist"]],
				"mystic": [["ward", "Invoke the totem ward to drive them off (10 lore)"], ["hold", "Fight with the spirits at our backs"], ["retreat", "Retreat across the river"]],
				"agrarian": [["reinforce", "Send help - we guard the larder"], ["hold", "Fight for our supplies"], ["retreat", "Run, and take what food we can"]],
				"lazy": [["retreat", "Go home. Please."], ["reinforce", "Send someone else to deal with them"], ["hold", "Fine, we fight"]],
			}[arch]
		"leader_wounded":
			speech = {
				"warrior": "Bah! A scratch - %s HP left. I've had worse from a cave bear. Let me keep going!" % sm["leader_hp"],
				"cautious": "Chieftain... I am hurt badly (%s HP). The work is %d%% done. A dead builder raises no huts." % [sm["leader_hp"], pct],
			}.get(arch, "Chieftain, I am wounded (%s HP) and the work is only %d%% done." % [sm["leader_hp"], pct])
			opts = [["rest", "Let me return to the bonfire; the crew carries on"], ["press_on", "I'll bind the wound and keep working"], ["retreat", "Abandon the contract"]]
			if arch == "warrior": opts = [opts[1], opts[0], opts[2]]
		"natural_disaster":
			speech = "Chieftain, the waters rise over the east bank! We are %d%% done - %s may be lost." % [pct, half]
			opts = [["shelter", "Shelter on high ground until the waters fall"], ["retreat", "Abandon the camp and save ourselves"]]
		_:
			speech = "Chieftain, something has gone wrong."
			opts = [["hold", "Hold"], ["retreat", "Retreat"]]
	var allowed: Array = ctx.get("allowed", [])
	var options: Array = []
	for o in opts:
		if allowed.is_empty() or o[0] in allowed: options.append({"effect": o[0], "label": o[1]})
	return {"speech": speech, "options": options}
