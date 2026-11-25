// A picked thing's outline (world_view selection styles): a crisp line round the sprite's
// opaque pixels and a softer halo beyond it. Shapes drawn without a texture (shadows,
// rings) are left as they are.
shader_type canvas_item;

uniform vec4 line_color : source_color = vec4(1.0, 0.86, 0.35, 1.0);
uniform float width = 3.0; // in texture pixels (sprites are baked at 2x)
uniform float halo = 0.45; // the halo's strength, 0 = none
uniform float pulse = 1.0; // 0..1, breathing

const vec2 DIRS[8] = {vec2(1, 0), vec2(-1, 0), vec2(0, 1), vec2(0, -1), vec2(0.7, 0.7), vec2(-0.7, 0.7), vec2(0.7, -0.7), vec2(-0.7, -0.7)};

void fragment() {
	vec4 c = COLOR;
	if (TEXTURE_PIXEL_SIZE.x < 0.5 && c.a < 0.5) { // (a real texture, and this pixel is outside the shape)
		float near = 0.0;
		float far = 0.0;
		for (int i = 0; i < 8; i++) {
			near = max(near, texture(TEXTURE, UV + DIRS[i] * TEXTURE_PIXEL_SIZE * width).a);
			far = max(far, texture(TEXTURE, UV + DIRS[i] * TEXTURE_PIXEL_SIZE * width * 2.6).a);
		}
		if (near > 0.5) c = vec4(line_color.rgb, line_color.a * (0.75 + 0.25 * pulse));
		else if (far > 0.5) c = vec4(line_color.rgb, line_color.a * halo * pulse);
	}
	COLOR = c;
}
