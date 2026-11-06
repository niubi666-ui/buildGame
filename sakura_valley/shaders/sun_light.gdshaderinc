// Shared sunlight: gaps in slow clouds let separate beams of sun through.
// The ground patches and the visible shafts in the air both use this one pattern, so they line up.

// Direction toward the sun. main.gd gives the DirectionalLight3D the same values.
const vec3 SUN_DIR = vec3(-0.5498, 0.6198, -0.5598);

float sun_gap(vec2 ground, float t) {
	vec2 q = ground * 0.0175 + vec2(t * 0.012, t * 0.007);
	q += 0.8 * vec2(sin(q.y * 1.7 + 1.3), sin(q.x * 1.9 + 4.1));
	float v = sin(q.x * 2.3 + 0.4) * sin(q.y * 2.1 + 2.2);
	v += 0.45 * sin(q.x * 4.7 + q.y * 1.3 + 5.0) * sin(q.y * 3.9 - q.x * 1.1 + 1.0);
	return smoothstep(-0.12, 0.38, v);
}

vec2 sun_ground_point(vec3 world) {
	return world.xz - SUN_DIR.xz / SUN_DIR.y * world.y;
}

// Brightness multiplier for a surface at this position.
float sun_light_at(vec3 world, float t) {
	return mix(0.55, 1.1, sun_gap(sun_ground_point(world), t));
}
