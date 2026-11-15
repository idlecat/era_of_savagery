// Ground shader: the low-res terrain map gives colour and type (alpha: 1 = land,
// ~0.55 = sand / bank, < 0.45 = water); seamless noise textures add crisp detail at
// any zoom - grass clumps and blades, sand grain, and animated water ripples.
shader_type canvas_item;

uniform sampler2D grass_tex : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D grain_tex : repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec2 world_size = vec2(3600.0, 2400.0);

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

	// land: large light/dark patches, mid clumps, fine blades and gaps
	vec3 landc = col * (0.80 + 0.36 * g1) * (0.90 + 0.20 * g2);
	landc += vec3(0.07, 0.08, 0.02) * smoothstep(0.62, 0.92, g3);
	landc -= vec3(0.06, 0.06, 0.04) * smoothstep(0.42, 0.12, g3);
	landc += vec3(0.04, 0.05, 0.01) * smoothstep(0.7, 0.95, g4);

	// sand and banks: grain and pebbles
	vec3 sandc = col * (0.88 + 0.22 * g2);
	sandc += vec3(0.07) * smoothstep(0.72, 0.95, g4);
	sandc -= vec3(0.08, 0.07, 0.05) * step(g3, 0.16);

	// water: two scrolling noise layers interfere into ripples and glints
	float r1 = texture(grass_tex, wp / 95.0 + vec2(TIME * 0.018, TIME * 0.032)).r;
	float r2 = texture(grass_tex, wp / 52.0 - vec2(TIME * 0.027, TIME * 0.012)).r;
	float rip = r1 * r2;
	vec3 waterc = col * (0.82 + 0.4 * rip);
	waterc += vec3(0.30, 0.34, 0.32) * smoothstep(0.40, 0.58, rip);
	// foam where water meets the bank
	float edge = smoothstep(0.30, 0.42, m.a) * (1.0 - smoothstep(0.42, 0.5, m.a));
	waterc = mix(waterc, vec3(0.85, 0.9, 0.88), edge * (0.35 + 0.4 * g3));

	vec3 outc = landc * land + sandc * sand + waterc * water;
	COLOR = vec4(outc, 1.0);
}
