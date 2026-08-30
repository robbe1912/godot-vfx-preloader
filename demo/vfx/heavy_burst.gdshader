shader_type spatial;
render_mode blend_add, unshaded, cull_disabled;

// Heavy on purpose: 3 stacked 8-octave fbm evaluations force real
// shader compilation work on first pipeline build.
uniform sampler2D noise_tex;
uniform float strength : hint_range(0.0, 3.0) = 1.0;

float fbm(vec2 p) {
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 8; i++) {
		sum += amp * texture(noise_tex, p).r;
		p = p * 2.03 + vec2(11.7, 7.3);
		amp *= 0.5;
	}
	return sum;
}

void fragment() {
	vec2 uv = UV * 3.0;
	float n = fbm(uv) + fbm(uv * 2.0 + 5.0) + fbm(uv * 4.0 - 3.0);
	vec3 col = vec3(n * 0.6, n * 0.9, n * 0.4) * strength;
	ALBEDO = col;
	EMISSION = col;
}
