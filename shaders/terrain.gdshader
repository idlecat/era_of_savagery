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
uniform sampler2D t_road_packed : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D t_road_stone : repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec3 m_grass = vec3(0.4);  // the textures' mean colours (to tint them toward the map)
uniform vec3 m_grass2 = vec3(0.4);
uniform vec3 m_meadow = vec3(0.4);
uniform vec3 m_dry = vec3(0.4);
uniform vec3 m_dirt = vec3(0.4);
uniform vec3 m_forest = vec3(0.4);
uniform vec3 m_road_packed = vec3(0.4);
uniform vec3 m_road_stone = vec3(0.4);
uniform vec2 world_size = vec2(3600.0, 2400.0);
uniform vec2 wear_size = vec2(3600.0, 2400.0);
uniform float cell_size = 30.0; // a wear/road cell, in world units
uniform float tile = 150.0;      // world units one ground texture covers
uniform float realism = 0.55;    // 0: the map's colour with the photo's detail; 1: the photo's own colour
uniform float clouds = 0.16;     // how dark the drifting cloud shadows get
uniform float use_photo = 1.0;
uniform float dryness = 0.0;     // the land (config/lands.json): 0 green parkland or wetter, 1 dry steppe
uniform vec3 sun_tint = vec3(1.2, 1.17, 0.9);   // land in the sun
uniform vec3 shade_tint = vec3(0.78, 0.88, 0.76); // land in shade
uniform float relief = 0.8;
uniform vec3 sky_col = vec3(0.62, 0.74, 0.84);  // what the water mirrors (world_view eases it by time and weather)
uniform vec3 glint_col = vec3(0.55, 0.52, 0.42); // sun or moon glints on the ripples     // how strongly the gentle rise and fall of the land is shaded   // 0: the old procedural ground (no textures loaded)

// A texture sampled twice (two scales, rotated) so its tiling doesn't show.
// The lie of the land: a low rolling height field (world units), for shading only.
float height(vec2 wp) {
	return texture(grass_tex, wp / 900.0 + vec2(0.21, 0.63)).r * 40.0
		+ texture(grass_tex, wp / 380.0 + vec2(0.71, 0.17)).r * 6.0;
}

// Slopes facing the sun (the baked sprites' sun: from the upper left of the screen,
// world -x and a little -y) are brighter, the far sides of rises a little darker.
float hillshade(vec2 wp) {
	float e = 18.0;
	float hx = height(wp + vec2(e, 0.0)) - height(wp - vec2(e, 0.0));
	float hy = height(wp + vec2(0.0, e)) - height(wp - vec2(0.0, e));
	vec3 n = normalize(vec3(-hx, -hy, 2.0 * e));
	vec3 sun = normalize(vec3(-0.85, -0.3, 0.75));
	return dot(n, sun) - dot(vec3(0.0, 0.0, 1.0), sun);
}

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
	float bank_jag = (g2 - 0.5) * 0.24 + (g3 - 0.5) * 0.08; // (a ragged, natural edge, not the texels' steps)
	float land = smoothstep(0.7 + bank_jag, 0.9 + bank_jag, m.a);
	float water = 1.0 - smoothstep(0.32, 0.46, m.a);
	float sand = (1.0 - land) * (1.0 - water);
	vec3 col = m.rgb;

	// ---- land
	vec3 landc;
	if (use_photo > 0.5) {
		vec4 mk = texture(mask_tex, UV);
		vec4 wt = texture(wear_tex, wp / wear_size);
		float worn = wt.a;
		// the road's look (roads.gd): 1 trail, 2 packed earth, 3 stone. Roads are laid in square
		// cells: taking the strongest of five nearby samples fills their diagonal steps into a
		// smooth band (and gives the road a little width).
		vec2 wc = wp / wear_size;
		vec2 hc = vec2(cell_size * 0.45) / wear_size;
		float road = max(max(wt.r, max(texture(wear_tex, wc + vec2(hc.x, hc.y)).r, texture(wear_tex, wc + vec2(-hc.x, hc.y)).r)),
			max(texture(wear_tex, wc + vec2(hc.x, -hc.y)).r, texture(wear_tex, wc + vec2(-hc.x, -hc.y)).r)) * 255.0 / 80.0;
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
		// built roads: packed earth with darker ditch edges, then laid stone (ragged edges)
		float jag = (g2 - 0.5) * 0.35;
		float packed_k = smoothstep(1.3 + jag, 1.75 + jag, road);
		float stone_k = smoothstep(2.3 + jag, 2.75 + jag, road);
		float ditch = smoothstep(0.95, 1.35, road + jag) * (1.0 - smoothstep(1.45, 1.8, road + jag));
		landc *= 1.0 - 0.22 * ditch;
		vec3 packed = tinted(photo(t_road_packed, wp, 0.5), m_road_packed, vec3(0.56, 0.48, 0.36));
		landc = mix(landc, packed, packed_k);
		vec3 stone = tinted(photo(t_road_stone, wp, 0.35), m_road_stone, vec3(0.52, 0.50, 0.46));
		landc = mix(landc, stone, stone_k);
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

	// ---- water: depth from the map's alpha (deep mid-river, shallow at the banks and fords),
	// the riverbed showing through the shallows, ripples that run with the current (the mask
	// holds each river pixel's flow direction; two phases of a flow map, cross-faded, so the
	// pattern never stretches), the sky mirrored on top, and sun glints on the ripple crests.
	float depth = 1.0 - smoothstep(0.1, 0.38, m.a);
	vec4 fm = texture(mask_tex, UV);
	vec2 flow = fm.b > 0.5 ? normalize(fm.rg * 2.0 - 1.0 + vec2(0.0001)) : vec2(0.7, 0.7);
	float ph0 = fract(TIME * 0.07);
	float ph1 = fract(TIME * 0.07 + 0.5);
	float wgt = abs(ph0 * 2.0 - 1.0); // (weight of the second phase: the first is reset when it is 0)
	vec2 o0 = flow * ph0 * 200.0;
	vec2 o1 = flow * ph1 * 200.0;
	float ra = mix(texture(grass_tex, (wp - o0) / 95.0).r, texture(grass_tex, (wp - o1) / 95.0 + vec2(0.5)).r, wgt);
	float rb = mix(texture(grass_tex, (wp - o0 * 1.4) / 46.0 + vec2(0.3, 0.1)).r, texture(grass_tex, (wp - o1 * 1.4) / 46.0 + vec2(0.8, 0.6)).r, wgt);
	float rip = ra * rb;
	vec3 bed = mix(vec3(0.42, 0.44, 0.34), vec3(0.34, 0.38, 0.30), g2) * (0.85 + 0.3 * g3);
	vec3 deepc = vec3(0.07, 0.25, 0.38);
	vec3 waterc = mix(mix(bed, col, 0.6), deepc, pow(depth, 0.8) * 0.85);
	waterc *= 0.78 + 0.55 * rip;
	waterc += vec3(0.16, 0.19, 0.2) * smoothstep(0.36, 0.55, rip); // (crests catching the light)
	float sky_n = texture(grass_tex, wp / 1900.0 + vec2(TIME * 0.0035, TIME * 0.0016)).r;
	waterc = mix(waterc, sky_col * (0.8 + 0.4 * sky_n), 0.1 + 0.1 * depth);
	float spark = texture(grain_tex, (wp - o0 * 0.6) / 13.0).r * (1.0 - wgt) + texture(grain_tex, (wp - o1 * 0.6) / 13.0 + vec2(0.4)).r * wgt;
	waterc += glint_col * smoothstep(0.62, 0.8, spark * rip * 1.9) * (0.4 + 0.6 * depth);
	float edge = smoothstep(0.30, 0.42, m.a) * (1.0 - smoothstep(0.42, 0.5, m.a)); // foam at the bank
	waterc = mix(waterc, vec3(0.85, 0.9, 0.88), edge * (0.3 + 0.45 * smoothstep(0.35, 0.7, ra)));

	landc *= 1.0 + relief * hillshade(wp) * vec3(1.0, 0.98, 0.92);
	vec3 outc = landc * land + sandc * sand + waterc * water;
	// ---- cloud shadows drifting over everything
	float cl = texture(grass_tex, wp / 2600.0 + vec2(TIME * 0.0035, TIME * 0.0016)).r;
	outc *= 1.0 - clouds * smoothstep(0.52, 0.72, cl);
	COLOR = vec4(outc, 1.0);
}
