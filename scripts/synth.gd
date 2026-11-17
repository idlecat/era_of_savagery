## Sounds made in code, like the sprites (art_baker.gd): a recipe from config/audio.json
## is rendered once into an AudioStreamWAV. No sound files ship with the game.
##
## Recipe: {"dur": s, "loop": bool, "gain": 0-1, "layers": [layer...]}; a layer:
##   "wave"   sine | tri | square | saw | noise | crackle (sparse clicks)
##   "freq"   Hz at the start, "to" Hz at the end (an exponential glide), "vib" [Hz, depth]
##   "at", "len" when the layer starts and how long it lasts (s; default the whole sound)
##   "attack", "decay" (s; the envelope rises, then falls exponentially for `decay`;
##            0 = holds), "vol" 0-1
##   "lp", "hp" one-pole low/high-pass cutoffs (Hz), "lp_to" glides the low-pass
##   "am" [Hz, depth] tremolo; "density" clicks per second for crackle
##   "harm" [[mult, vol]...] extra partials of a tonal wave (a flute's breath, a horn)
## Loops get a short crossfade so they wrap without a click.
extends RefCounted

const RATE := 22050

static var _cache := {}

static func clear() -> void: _cache.clear()

## The stream for recipe `id` of `recipes` (rendered on first use, then cached).
static func stream(id: String, recipes: Dictionary) -> AudioStreamWAV:
	if _cache.has(id): return _cache[id]
	if not recipes.has(id): return null
	var w := render(recipes[id])
	_cache[id] = w
	return w

static func render(r: Dictionary) -> AudioStreamWAV:
	var dur := clampf(float(r.get("dur", 0.5)), 0.02, 12.0)
	var n := int(dur * RATE)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(JSON.stringify(r)) # (the same recipe always sounds the same)
	for l in r.get("layers", []): _layer(buf, l, dur, rng)
	var loop: bool = r.get("loop", false)
	if loop:
		_crossfade(buf, mini(n / 8, int(0.08 * RATE)))
		n = buf.size()
	# normalise to the recipe's gain
	var peak := 0.0001
	for v in buf: peak = maxf(peak, absf(v))
	var g := float(r.get("gain", 0.8)) / peak
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n: data.encode_s16(i * 2, int(clampf(buf[i] * g, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = n
	return w

static func _layer(buf: PackedFloat32Array, l: Dictionary, dur: float, rng: RandomNumberGenerator) -> void:
	var t0 := float(l.get("at", 0.0))
	var span := float(l.get("len", dur - t0))
	var i0 := int(t0 * RATE)
	var i1 := mini(buf.size(), int((t0 + span) * RATE))
	if i1 <= i0: return
	var wave: String = l.get("wave", "sine")
	var f0 := float(l.get("freq", 220.0))
	var f1 := float(l.get("to", f0))
	var vol := float(l.get("vol", 1.0))
	var attack := maxf(0.001, float(l.get("attack", 0.005)))
	var decay := float(l.get("decay", 0.0))
	var vib: Array = l.get("vib", [0, 0])
	var am: Array = l.get("am", [0, 0])
	var harm: Array = l.get("harm", [])
	var lp := float(l.get("lp", 0.0))
	var lp_to := float(l.get("lp_to", lp))
	var hp := float(l.get("hp", 0.0))
	var density := float(l.get("density", 30.0))
	var phase := 0.0
	var lp_y := 0.0
	var hp_y := 0.0
	var hp_x := 0.0
	var crackle := 0.0
	var dt := 1.0 / RATE
	var n := i1 - i0
	for k in n:
		var t := k * dt
		var u := float(k) / n
		var f := f0 * pow(f1 / f0, u) if f0 > 0 and f1 > 0 else f0
		if vib[0] > 0: f *= 1.0 + float(vib[1]) * sin(TAU * float(vib[0]) * t)
		phase = fmod(phase + f * dt, 1.0)
		var s := 0.0
		match wave:
			"sine": s = sin(TAU * phase)
			"tri": s = 1.0 - 4.0 * absf(phase - 0.5)
			"square": s = 1.0 if phase < 0.5 else -1.0
			"saw": s = 2.0 * phase - 1.0
			"noise": s = rng.randf_range(-1.0, 1.0)
			"crackle":
				if rng.randf() < density * dt: crackle = rng.randf_range(0.4, 1.0) * (1.0 if rng.randf() < 0.5 else -1.0)
				s = crackle
				crackle *= 0.86
		for h in harm: s += sin(TAU * fmod(phase * float(h[0]), 1.0)) * float(h[1])
		# envelope
		var e := minf(1.0, t / attack)
		if decay > 0: e *= exp(-maxf(0.0, t - attack) / decay)
		e *= minf(1.0, (span - t) / 0.01) # (no click at the end)
		if am[0] > 0: e *= 1.0 - float(am[1]) * (0.5 + 0.5 * sin(TAU * float(am[0]) * t))
		s *= e
		# filters
		if lp > 0:
			var c := lerpf(lp, lp_to, u)
			var a := 1.0 - exp(-TAU * c * dt)
			lp_y += a * (s - lp_y)
			s = lp_y
		if hp > 0:
			var rc := 1.0 / (TAU * hp)
			var b := rc / (rc + dt)
			hp_y = b * (hp_y + s - hp_x)
			hp_x = s
			s = hp_y
		buf[i0 + k] += s * vol

static func _crossfade(buf: PackedFloat32Array, m: int) -> void:
	if m < 2: return
	var n := buf.size()
	for i in m: # blend the tail into the head so the end meets the start
		var a := float(i) / m
		buf[i] = buf[i] * a + buf[n - m + i] * (1.0 - a)
	buf.resize(n - m)
