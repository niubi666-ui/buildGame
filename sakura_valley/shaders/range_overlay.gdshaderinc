// Paints a selected tower's firing cone onto whatever surface includes this.
// The cone is worked out per pixel, so it follows the ground exactly, even on steep walls.
uniform float range_on = 0.0;
uniform vec3 range_apex = vec3(0.0);
uniform vec3 range_aim = vec3(0.0, 0.0, 1.0);
uniform float range_cos = 0.8;
uniform float range_dist = 60.0;
// Nothing nearer than range_min can be hit. A lobbing tower measures distance flat along the ground.
uniform float range_min = 0.0;
uniform float range_flat = 0.0;
// Line of sight per grid cell, from visibility_map in native/path_core.cpp.
uniform sampler2D range_map : filter_linear, repeat_disable;
uniform vec2 range_size_res = vec2(320.0, 257.0);

// rgb is the tint and a is how strongly to apply it. Gold can be hit, red is blocked by terrain.
vec4 range_overlay(vec3 surface_point) {
	vec3 offset = surface_point + vec3(0.0, 1.1, 0.0) - range_apex;
	float dist = range_flat > 0.5 ? length(offset.xz) : length(offset);
	if (dist > range_dist || dist < max(range_min, 0.001)) {
		return vec4(0.0);
	}
	float along = range_flat > 0.5 ? 1.0 : dot(normalize(offset), range_aim);
	if (along < range_cos) {
		return vec4(0.0);
	}
	float res = range_size_res.y;
	vec2 uv = (surface_point.xz / range_size_res.x + 0.5) * (res - 1.0) / res + 0.5 / res;
	float seen = textureLod(range_map, uv, 0.0).r;
	vec3 tint = mix(vec3(0.74, 0.25, 0.2), vec3(0.98, 0.76, 0.34), smoothstep(0.35, 0.65, seen));
	float rim = max(1.0 - smoothstep(0.0, 0.012, along - range_cos), 1.0 - smoothstep(0.0, 0.9, range_dist - dist));
	if (range_min > 0.0) {
		rim = max(rim, 1.0 - smoothstep(0.0, 0.9, dist - range_min));
	}
	return vec4(tint, mix(0.26, 0.72, rim));
}
