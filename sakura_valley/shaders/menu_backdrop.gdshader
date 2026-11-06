shader_type canvas_item;
// The menu's backdrop: a soft morning sky, layers of distant hills and a few drifting petals.

uniform vec3 sky_top : source_color = vec3(0.83, 0.9, 0.94);
uniform vec3 sky_low : source_color = vec3(0.99, 0.95, 0.9);
uniform vec3 hill_far : source_color = vec3(0.78, 0.86, 0.84);
uniform vec3 hill_mid : source_color = vec3(0.67, 0.79, 0.66);
uniform vec3 hill_near : source_color = vec3(0.55, 0.7, 0.5);
uniform vec3 petal : source_color = vec3(0.96, 0.74, 0.8);

float hash(float n) {
	return fract(sin(n) * 43758.5453);
}

// A smooth ridge line across the screen, as a height from the bottom.
float ridge(float x, float seed, float height, float bumps) {
	float y = height;
	y += sin(x * 3.1 + seed) * 0.035 * bumps;
	y += sin(x * 7.3 + seed * 2.1) * 0.016 * bumps;
	y += sin(x * 17.0 + seed * 3.7) * 0.006 * bumps;
	return y;
}

void fragment() {
	vec2 uv = UV;
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec3 color = mix(sky_top, sky_low, smoothstep(0.0, 0.75, uv.y));
	// Warm light from the upper left.
	color += vec3(0.05, 0.035, 0.0) * (1.0 - smoothstep(0.0, 0.9, length(uv - vec2(0.12, 0.05))));
	float drift = TIME * 0.004;
	float up = 1.0 - uv.y;
	float far_line = ridge(uv.x + drift * 0.3, 1.3, 0.33, 1.4);
	color = mix(color, hill_far, smoothstep(far_line + 0.002, far_line - 0.002, up) * 0.85);
	float mid_line = ridge(uv.x + drift * 0.6, 4.7, 0.22, 1.1);
	color = mix(color, hill_mid, smoothstep(mid_line + 0.002, mid_line - 0.002, up) * 0.8);
	float near_line = ridge(uv.x + drift, 9.1, 0.11, 0.9);
	color = mix(color, hill_near, smoothstep(near_line + 0.002, near_line - 0.002, up) * 0.75);
	// A haze band where the hills meet the sky.
	color = mix(color, sky_low, (1.0 - smoothstep(0.0, 0.08, abs(up - 0.3))) * 0.18);

	// Petals: each one falls along its own swaying line.
	for (int n = 0; n < 26; n++) {
		float f = float(n);
		float speed = 0.025 + hash(f * 3.1) * 0.03;
		float y = fract(hash(f * 7.7) + TIME * speed);
		float x = fract(hash(f * 1.9) + sin(TIME * 0.4 + f) * 0.02 + y * 0.12);
		vec2 d = (uv - vec2(x, y)) * vec2(aspect, 1.0);
		float angle = TIME * (0.6 + hash(f) * 0.8) + f;
		vec2 r = vec2(d.x * cos(angle) - d.y * sin(angle), d.x * sin(angle) + d.y * cos(angle));
		float size = 0.0045 + hash(f * 5.3) * 0.004;
		float shape = length(r / vec2(size, size * 0.55));
		color = mix(color, petal, (1.0 - smoothstep(0.7, 1.0, shape)) * 0.85);
	}
	COLOR = vec4(color, 1.0);
}
