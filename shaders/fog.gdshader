// Fog of war, drawn through the iso transform over the world. The fog texture has one
// texel per fog cell (alpha: 0 in sight, ~0.47 explored, 1 never seen), linearly filtered.
// Explored land out of sight is the world remembered: faded, cooler and darker (read from
// the screen, so it keeps its detail). Unexplored land is a bank of dark drifting mist with
// a pale rim where it meets the known world, not a flat black hole.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;
uniform vec2 fog_world = vec2(3600.0, 2400.0); // world units the fog texture covers
uniform vec3 night_tint = vec3(1.0); // the CanvasModulate colour (undone on what we read back)
uniform vec3 mist_col = vec3(0.10, 0.095, 0.09);
uniform vec3 rim_col = vec3(0.55, 0.52, 0.46);

void fragment() {
	// a small blur over the cells so the edge of sight is a soft curve, not a staircase
	vec2 px = 0.75 / vec2(textureSize(TEXTURE, 0));
	float v = (texture(TEXTURE, UV).a * 2.0 + texture(TEXTURE, UV + vec2(px.x, px.y)).a + texture(TEXTURE, UV + vec2(-px.x, px.y)).a
		+ texture(TEXTURE, UV + vec2(px.x, -px.y)).a + texture(TEXTURE, UV + vec2(-px.x, -px.y)).a) / 6.0;
	vec2 wp = UV * fog_world;
	// drifting mist: two layers sliding past each other
	float n1 = texture(noise_tex, wp / 1700.0 + vec2(TIME * 0.004, TIME * 0.002)).r;
	float n2 = texture(noise_tex, wp / 640.0 - vec2(TIME * 0.006, -TIME * 0.003)).r;
	float mist = n1 * 0.6 + n2 * 0.4;
	// ragged edges: the noise pushes the boundaries in and out
	float jag = (mist - 0.5) * 0.22;
	float remembered = smoothstep(0.08 + jag * 0.5, 0.42 + jag * 0.5, v);
	float unknown = smoothstep(0.62 + jag, 0.9 + jag, v);

	vec3 seen = texture(screen_tex, SCREEN_UV).rgb / max(night_tint, vec3(0.05));
	float l = dot(seen, vec3(0.299, 0.587, 0.114));
	vec3 memory = mix(vec3(l), seen, 0.25) * vec3(0.66, 0.68, 0.74);
	vec3 col = mix(seen, memory, remembered);

	// the mist bank: darker in the deep unknown, lighter wisps, a pale rim at its edge
	vec3 deep = mist_col * (0.7 + 0.8 * smoothstep(0.35, 0.7, mist));
	float rim = unknown * (1.0 - smoothstep(0.92, 1.0, v + jag * 0.3));
	deep = mix(deep, rim_col * (0.55 + 0.45 * n2), rim * 0.4);
	col = mix(col, deep, unknown);
	COLOR = vec4(col, 1.0); // (in sight: the screen as it was, so the seam doesn't show)
}
