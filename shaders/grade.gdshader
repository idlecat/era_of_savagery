shader_type canvas_item;
// Subtle full-screen colour grade (saturation / contrast) that lies over the world
// and under the vignette. Parameters are eased per-season and per-weather by
// world_view.gd so the mood drifts instead of snapping.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float contrast : hint_range(0.5, 1.5) = 1.0;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(l), c, saturation);
	c = (c - 0.5) * contrast + 0.5;
	COLOR = vec4(c, 1.0);
}
