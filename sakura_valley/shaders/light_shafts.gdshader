shader_type spatial;
// Full-screen pass. Adds light scattered by the sun beams, and darkens the screen edges.
// The beams are soft, so they are marched per vertex on a coarse screen grid, which costs almost nothing.
render_mode unshaded, blend_premul_alpha, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/sun_light.gdshaderinc"

const int STEPS = 12;

uniform vec3 beam_color : source_color = vec3(1.0, 0.91, 0.74);
uniform float beam_strength = 0.2;
uniform float density = 0.0085;
uniform float air_top = 85.0;
uniform float vignette = 0.42;

varying float scatter;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.5, 1.0);
	vec3 dir = normalize(mat3(INV_VIEW_MATRIX) * (view.xyz / view.w));
	vec3 start = CAMERA_POSITION_WORLD;

	// March through the layer of air between the valley floor and air_top.
	float enter = 0.0;
	float leave = 900.0;
	if (abs(dir.y) > 0.0001) {
		float at_top = (air_top - start.y) / dir.y;
		float at_floor = (0.0 - start.y) / dir.y;
		if (dir.y < 0.0) {
			enter = max(enter, at_top);
			leave = min(leave, at_floor);
		} else {
			leave = min(leave, at_top);
		}
	}
	// A limited reach keeps distant air clear, so the beams stay separate instead of adding up to fog.
	float span = clamp(leave - enter, 0.0, 170.0);
	float sum = 0.0;
	for (int i = 0; i < STEPS; i++) {
		vec3 p = start + dir * (enter + span * (float(i) + 0.5) / float(STEPS));
		float thin = clamp(1.0 - p.y / air_top, 0.0, 1.0);
		sum += sun_gap(sun_ground_point(p), TIME) * thin;
	}
	// Removing the average level leaves bright beams over clear air.
	float beams = max(sum / float(STEPS) - 0.14, 0.0);
	scatter = 1.0 - exp(-beams * span * density);
}

void fragment() {
	vec2 from_center = (SCREEN_UV - 0.5) * vec2(1.05, 1.2);
	float edge = smoothstep(0.32, 0.86, length(from_center));
	ALBEDO = beam_color * scatter * beam_strength;
	ALPHA = edge * vignette;
}
