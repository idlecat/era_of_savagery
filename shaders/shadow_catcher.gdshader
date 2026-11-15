// Invisible ground plane that only shows the shadows cast onto it, so baked sprites
// carry soft contact shadows on a transparent background.
shader_type spatial;
render_mode shadow_to_opacity, specular_disabled;

void fragment() {
	ALBEDO = vec3(0.02, 0.02, 0.05);
}
