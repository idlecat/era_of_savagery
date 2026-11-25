shader_type canvas_item;
// Full-screen grade that lies over the world and under the vignette and the HUD.
// world_view.gd eases its parameters per time of day, season and weather, so the mood
// drifts instead of snapping:
// - bloom: bright things (fires, torches, sunlit snow) bleed soft light into their
//   surroundings, read from the screen's own mipmaps (cheap, no extra passes);
// - split toning: shadows lean cool, highlights warm, like late sun on a meadow;
// - a gentle filmic shoulder so highlights roll off instead of clipping;
// - at night the darks are lifted toward moonlight blue rather than crushed to mud.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float contrast : hint_range(0.5, 1.5) = 1.0;
uniform float bloom : hint_range(0.0, 2.0) = 0.25;      // strength
uniform float bloom_from : hint_range(0.0, 1.0) = 0.62; // luminance where it begins
uniform vec3 shadow_tone = vec3(0.92, 0.98, 1.08);
uniform vec3 light_tone = vec3(1.06, 1.01, 0.92);
uniform float tone_k : hint_range(0.0, 1.0) = 0.5;      // how strong the split toning is
uniform float moon : hint_range(0.0, 1.0) = 0.0;        // night: lift the darks toward blue

vec3 bright(vec2 uv, float lod) {
	vec3 c = textureLod(screen_tex, uv, lod).rgb;
	float l = max(c.r, max(c.g, c.b));
	return c * smoothstep(bloom_from, bloom_from + 0.3, l);
}

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	// bloom: three widths of blur, the wider ones weaker
	vec3 b = bright(SCREEN_UV, 2.0) * 0.5 + bright(SCREEN_UV, 4.0) * 0.35 + bright(SCREEN_UV, 6.0) * 0.25;
	c += b * bloom;
	// moonlight: lift the darks a little, cool and soft
	c = mix(c, c * 0.85 + vec3(0.035, 0.05, 0.09), moon);
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	// split toning (weighted by luminance), then saturation and contrast
	vec3 tone = mix(shadow_tone, light_tone, smoothstep(0.15, 0.75, l));
	c *= mix(vec3(1.0), tone, tone_k);
	l = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(l), c, saturation);
	c = (c - 0.5) * contrast + 0.5;
	// filmic shoulder: above ~0.8 roll off toward 1 instead of clipping
	c = mix(c, 1.0 - 0.2 * exp(-(c - 0.8) / 0.2), step(0.8, c));
	COLOR = vec4(clamp(c, 0.0, 1.0), 1.0);
}
