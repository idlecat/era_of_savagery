// Ground shader. The low-res terrain map gives colour and type (alpha: 1 = land,
// ~0.55 = sand / bank, < 0.45 = water); the mask map says where the soil, the forest
// floor and the meadows are (r, g, b); the wear map, where feet have worn paths.
// Land is painted with photographic CC0 ground textures (assets/textures/terrain,
// assets/CREDITS.md): each is sampled twice at different scales and angles so it never
// visibly repeats, tinted toward the map's colour so the game keeps its palette, and
// mixed by large slow patches (green, olive, dry) like a real meadow. Cloud shadows drift
// over it. Sand and water stay procedural (noise textures).
shader_type canvas_item;

uniform sampler2D grass_tex : repeat_enable, filter_linear_mipmap_anisotropic; // (noise: patches, ripples)
uniform sampler2D grain_tex : repeat_enable, filter_linear_mipmap_anisotropic; // (noise: grain)
uniform sampler2D mask_tex : filter_linear;
uniform sampler2D wear_tex : filter_linear;
uniform sampler2D t_grass : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D t_grass2 : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D t_meadow : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D t_dry : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D t_dirt : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D t_forest : repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec3 m_grass = vec3(0.4);  // the textures' mean colours (to tint them toward the map)
uniform vec3 m_grass2 = vec3(0.4);
uniform vec3 m_meadow = vec3(0.4);
uniform vec3 m_dry = vec3(0.4);
uniform vec3 m_dirt = vec3(0.4);
uniform vec3 m_forest = vec3(0.4);
uniform vec2 world_size = vec2(3600.0, 2400.0);
uniform vec2 wear_size = vec2(3600.0, 2400.0);
uniform float tile = 150.0;      // world units one ground texture covers
uniform float realism = 0.55;    // 0: the map's colour with the photo's detail; 1: the photo's own colour
uniform float clouds = 0.16;     // how dark the drifting cloud shadows get
uniform float use_photo = 1.0;
uniform float dryness = 0.0;     // the land (config/lands.json): 0 green parkland or wetter, 1 dry steppe
uniform vec3 sun_tint = vec3(1.2, 1.17, 0.9);   // land in the sun
uniform vec3 shade_tint = vec3(0.78, 0.88, 0.76); // land in shade   // 0: the old procedural ground (no textures loaded)

// A texture sampled twice (two scales, rotated) so its tiling doesn't show.
vec3 photo(sampler2D t, vec2 wp, float s) {
	vec2 a = wp / (tile * s);
	vec2 b = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * wp / (tile * s * 1.37) + vec2(0.31, 0.77);
	return mix(texture(t, a).rgb, texture(t, b).rgb, 0.5);
}

// Tint a photo toward a target colour: keep its detail (its ratio to its own mean) and,
// by `realism`, some of its own colour.
vec3 tinted(vec3 c, vec3 mean, vec3 target) {
	vec3 detail = c / max(mean, vec3(0.02));
	vec3 own = c * (dot(target, vec3(0.333)) / max(dot(mean, vec3(0.333)), 0.02));
	return mix(target * detail, own, realism);
}

void fragment() {
	vec4 m = texture(TEXTURE, UV);
	vec2 wp = UV * world_size;
	float g1 = texture(grass_tex, wp / 170.0).r;
	float g2 = texture(grass_tex, wp / 41.0 + vec2(0.37, 0.11)).r;
	float g3 = texture(grain_tex, wp / 11.0).r;
	float g4 = texture(grain_tex, wp / 4.3 + vec2(0.5, 0.2)).r;
	float land = smoothstep(0.7, 0.95, m.a);
	float water = 1.0 - smoothstep(0.32, 0.46, m.a);
	float sand = (1.0 - land) * (1.0 - water);
	vec3 col = m.rgb;

	// ---- land
	vec3 landc;
	if (use_photo > 0.5) {
		vec4 mk = texture(mask_tex, UV);
		float worn = texture(wear_tex, wp / wear_size).a;
		// large slow patches: lush green, olive, dry (like sun and soil differ across a meadow)
		float p1 = texture(grass_tex, wp / 1300.0 + vec2(0.13, 0.71)).r;
		float p2 = texture(grass_tex, wp / 620.0 + vec2(0.55, 0.29)).r;
		vec3 grass = tinted(photo(t_grass, wp, 1.0), m_grass, col);
		vec3 grass2 = tinted(photo(t_grass2, wp, 1.3), m_grass2, col * vec3(1.02, 1.0, 0.92));
		vec3 meadow = tinted(photo(t_meadow, wp, 1.6), m_meadow, col * vec3(1.12, 1.1, 0.78));
		vec3 dry = tinted(photo(t_dry, wp, 1.2), m_dry, mix(col, vec3(0.62, 0.58, 0.36), 0.55));
		landc = mix(grass, grass2, smoothstep(0.35, 0.65, p2));
		landc = mix(landc, meadow, smoothstep(0.55, 0.8, p1) * 0.75 + mk.b * 0.4);
		landc = mix(landc, dry, smoothstep(0.66 - 0.3 * dryness, 0.86 - 0.2 * dryness, p2 * 0.6 + p1 * 0.4) * (0.55 + 0.35 * dryness));
		// sun and shade across the land: sunny stretches warm and yellow, shaded hollows deep green
		float lit = smoothstep(0.2, 0.8, p1 * 0.7 + p2 * 0.3);
		landc *= mix(shade_tint, sun_tint, lit);
		// the forest floor, then bare soil (the village ground, dirt patches, worn paths)
		vec3 forest = tinted(photo(t_forest, wp, 0.9), m_forest, mix(col, vec3(0.32, 0.30, 0.18), 0.4));
		landc = mix(landc, forest, clamp(mk.g * 1.3, 0.0, 0.9));
		vec3 dirt = tinted(photo(t_dirt, wp, 0.8), m_dirt, vec3(0.50, 0.42, 0.30));
		float soil = clamp(max(mk.r, smoothstep(0.08, 0.45, worn)), 0.0, 1.0);
		soil *= 0.75 + 0.5 * smoothstep(0.3, 0.7, g2); // (ragged edges: grass creeps in)
		landc = mix(landc, dirt, clamp(soil, 0.0, 0.95));
	} else {
		landc = col * (0.80 + 0.36 * g1) * (0.90 + 0.20 * g2);
		landc += vec3(0.07, 0.08, 0.02) * smoothstep(0.62, 0.92, g3);
		landc -= vec3(0.06, 0.06, 0.04) * smoothstep(0.42, 0.12, g3);
		landc += vec3(0.04, 0.05, 0.01) * smoothstep(0.7, 0.95, g4);
	}

	// ---- sand and banks: grain and pebbles
	vec3 sandc = col * (0.88 + 0.22 * g2);
	sandc += vec3(0.07) * smoothstep(0.72, 0.95, g4);
	sandc -= vec3(0.08, 0.07, 0.05) * step(g3, 0.16);

	// ---- water: two scrolling noise layers interfere into ripples and glints
	float r1 = texture(grass_tex, wp / 95.0 + vec2(TIME * 0.018, TIME * 0.032)).r;
	float r2 = texture(grass_tex, wp / 52.0 - vec2(TIME * 0.027, TIME * 0.012)).r;
	float rip = r1 * r2;
	vec3 waterc = col * (0.82 + 0.4 * rip);
	waterc += vec3(0.30, 0.34, 0.32) * smoothstep(0.40, 0.58, rip);
	float edge = smoothstep(0.30, 0.42, m.a) * (1.0 - smoothstep(0.42, 0.5, m.a)); // foam at the bank
	waterc = mix(waterc, vec3(0.85, 0.9, 0.88), edge * (0.35 + 0.4 * g3));

	vec3 outc = landc * land + sandc * sand + waterc * water;
	// ---- cloud shadows drifting over everything
	float cl = texture(grass_tex, wp / 2600.0 + vec2(TIME * 0.0035, TIME * 0.0016)).r;
	outc *= 1.0 - clouds * smoothstep(0.52, 0.72, cl);
	COLOR = vec4(outc, 1.0);
}
