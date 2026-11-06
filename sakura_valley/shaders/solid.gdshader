shader_type spatial;
render_mode diffuse_burley, world_vertex_coords;

#include "res://shaders/common.gdshaderinc"
#include "res://shaders/terrain_state.gdshaderinc"
#include "res://shaders/sun_light.gdshaderinc"

uniform vec3 albedo : source_color = vec3(1.0);
uniform float variation = 0.14;
uniform float noise_scale = 2.0;
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform float roughness = 0.88;
// 0: fixed in place. 1: follows the ground. 2: follows the ground, hidden on bare earth.
// 3: stays on the water surface, hidden when that spot is no longer water.
uniform int ground_rule = 0;
uniform float water_level = 2.0;

varying vec3 world_pos;
varying vec3 instance_tint;

void vertex() {
	if (ground_rule > 0) {
		vec3 root = MODEL_MATRIX[3].xyz;
		vec4 state = sample_state(root.xz);
		bool hidden = false;
		if (ground_rule == 3) {
			hidden = state.r >= water_level;
		} else {
			// INSTANCE_CUSTOM.x holds the ground height when this item was placed.
			VERTEX.y += state.r - INSTANCE_CUSTOM.x;
			if (ground_rule == 2) {
				hidden = state.r < water_level + 0.5 || state.g > 0.28 || state_normal(state).y < 0.64;
			}
		}
		if (hidden) {
			VERTEX = vec3(root.x, -500.0, root.z);
		}
	}
	world_pos = VERTEX;
	instance_tint = COLOR.rgb;
}

void fragment() {
	float n = fbm(vec2(world_pos.x + world_pos.z * 0.7, world_pos.y + world_pos.z * 0.3) * noise_scale);
	ALBEDO = albedo * instance_tint * (1.0 + (n - 0.5) * 2.0 * variation) * sun_light_at(world_pos, TIME);
	ROUGHNESS = roughness;
	SPECULAR = 0.25;
	EMISSION = emission * emission_energy;
}
