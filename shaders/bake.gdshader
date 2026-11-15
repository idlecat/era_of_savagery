// Material for the 3D sprite baker: triplanar noise texture for surface detail
// (bark, thatch, hide, stone, foliage) plus optional snow on upward-facing surfaces.
shader_type spatial;
render_mode diffuse_lambert_wrap, specular_disabled;

uniform vec3 base_color : source_color = vec3(0.6);
uniform sampler2D detail : repeat_enable, filter_linear_mipmap;
uniform vec3 stretch = vec3(1.0);   // >1 along an axis = streaks (thatch, bark)
uniform float scale = 0.08;
uniform float contrast = 0.45;
uniform float snow = 0.0;
uniform float rough = 0.9;

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 p = wpos * scale / stretch;
	vec3 w = pow(abs(wnorm), vec3(4.0));
	w /= (w.x + w.y + w.z);
	float n = texture(detail, p.yz).r * w.x + texture(detail, p.xz).r * w.y + texture(detail, p.xy).r * w.z;
	vec3 col = base_color * (1.0 - contrast * 0.5 + contrast * n);
	float s = snow * smoothstep(0.35, 0.7, wnorm.y);
	col = mix(col, vec3(0.94, 0.96, 1.0), s);
	ALBEDO = col;
	ROUGHNESS = rough;
}
