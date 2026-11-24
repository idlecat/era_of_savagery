// Material for the 3D sprite baker: triplanar noise texture for surface detail
// (bark, thatch, hide, stone, foliage) plus optional snow (or moss) on upward-facing
// surfaces, countershading (a pale underside below a height), stripes, and a little
// darkening where things meet the ground.
shader_type spatial;
render_mode diffuse_lambert_wrap, specular_disabled;

uniform vec3 base_color : source_color = vec3(0.6);
uniform sampler2D detail : repeat_enable, filter_linear_mipmap;
uniform vec3 stretch = vec3(1.0);   // >1 along an axis = streaks (thatch, bark)
uniform float scale = 0.08;
uniform float contrast = 0.45;
uniform float snow = 0.0;
uniform vec3 snow_color : source_color = vec3(0.94, 0.96, 1.0);
uniform float rough = 0.9;
// countershading, in the mesh's own space: under_color below under_y
uniform vec3 under_color : source_color = vec3(1.0);
uniform float under_amt = 0.0;
uniform float under_y = 0.0;
uniform float under_soft = 1.5;
// stripes across stripe_axis (mesh space), wavy so they read as painted, not banded
uniform vec3 stripe_color : source_color = vec3(0.1);
uniform float stripe_amt = 0.0;
uniform vec3 stripe_axis = vec3(0.0, 0.0, 1.0);
uniform float stripe_freq = 1.0;
uniform float ground_ao = 0.25;

varying vec3 wpos;
varying vec3 wnorm;
varying vec3 opos;

void vertex() {
	opos = VERTEX;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 p = wpos * scale / stretch;
	vec3 w = pow(abs(wnorm), vec3(4.0));
	w /= (w.x + w.y + w.z);
	float n = texture(detail, p.yz).r * w.x + texture(detail, p.xz).r * w.y + texture(detail, p.xy).r * w.z;
	float shade = 1.0 - contrast * 0.5 + contrast * n;
	vec3 col = base_color * shade;
	if (under_amt > 0.0) {
		float u = under_amt * (1.0 - smoothstep(under_y - under_soft, under_y + under_soft, opos.y + (n - 0.5) * under_soft));
		col = mix(col, under_color * shade, u);
	}
	if (stripe_amt > 0.0) {
		float t = dot(opos, stripe_axis) * stripe_freq + 1.4 * sin(opos.y * 0.7 + opos.x * 0.45) + (n - 0.5) * 2.0;
		float s = smoothstep(0.45, 0.8, sin(t)) * stripe_amt;
		if (under_amt > 0.0) s *= smoothstep(under_y - 0.5, under_y + 1.5, opos.y);
		col = mix(col, stripe_color, s);
	}
	col *= mix(1.0 - ground_ao, 1.0, smoothstep(0.0, 5.0, wpos.y));
	float s = snow * smoothstep(0.35, 0.7, wnorm.y);
	col = mix(col, snow_color, s);
	// a light final grade: a touch more saturation, a gentle S-curve, and warm
	// crowns over cool depths, so every model reads a little richer at map zoom
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(lum), col, 1.12);
	float sc = lum * lum * (3.0 - 2.0 * lum);
	col = mix(col, col * (sc / max(lum, 1e-4)), 0.35);
	col *= mix(vec3(0.98, 0.99, 1.04), vec3(1.05, 1.02, 0.96), smoothstep(0.0, 40.0, wpos.y));
	ALBEDO = col;
	ROUGHNESS = rough;
}
