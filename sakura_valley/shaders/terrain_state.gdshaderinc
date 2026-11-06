// Live terrain data shared with the GPU, per vertex: height, dig depth, normal x, normal z.
// Terrain, grass and rocks all read it, so one texture upload moves all of them together.
uniform sampler2D terrain_state : filter_linear, repeat_disable;
uniform vec2 terrain_size_res = vec2(320.0, 513.0);

vec4 sample_state(vec2 p) {
	float res = terrain_size_res.y;
	vec2 uv = (p / terrain_size_res.x + 0.5) * (res - 1.0) / res + 0.5 / res;
	return textureLod(terrain_state, uv, 0.0);
}

vec3 state_normal(vec4 s) {
	return vec3(s.b, sqrt(max(1.0 - s.b * s.b - s.a * s.a, 0.0)), s.a);
}
