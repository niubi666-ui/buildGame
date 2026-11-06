// Shared noise and meadow color, used by the terrain and grass so they blend.
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
			mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Each octave is rotated, which hides the square noise grid.
float fbm(vec2 p) {
	float a = 0.5;
	float v = 0.0;
	mat2 turn = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	p = turn * p;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise(p);
		p = turn * p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v / 0.875;
}

vec3 srgb(vec3 c) {
	return pow(c, vec3(2.2));
}

