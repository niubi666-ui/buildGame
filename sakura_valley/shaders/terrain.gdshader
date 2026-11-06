shader_type spatial;
render_mode diffuse_burley;

#include "res://shaders/common.gdshaderinc"
#include "res://shaders/meadow.gdshaderinc"
#include "res://shaders/terrain_state.gdshaderinc"
#include "res://shaders/sun_light.gdshaderinc"
#include "res://shaders/range_overlay.gdshaderinc"

uniform float water_level = 2.0;
uniform float dig_scale = 14.0;
uniform vec3 haze_color : source_color = vec3(0.7, 0.8, 0.9);

// On for the playable terrain, whose shape comes from the live state texture.
uniform bool live_terrain = false;

varying vec3 world_pos;
varying vec3 world_normal;
varying float dig_depth;

void vertex() {
	dig_depth = COLOR.r * dig_scale;
	if (live_terrain) {
		vec4 state = sample_state(VERTEX.xz);
		VERTEX.y = state.r;
		NORMAL = state_normal(state);
		dig_depth = state.g;
	}
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	float dig = dig_depth;
	float path = COLOR.g;
	float slope = 1.0 - world_normal.y;
	float grain = fbm(world_pos.xz * 0.8);
	// Sampled along the height too, so steep walls do not smear into vertical streaks.
	float fine = fbm(vec2(world_pos.x + world_pos.z * 0.6, world_pos.y * 1.7 + world_pos.z * 0.8) * 2.6);

	vec3 grass = meadow_color(world_pos.xz) * mix(0.62, 0.8, grain);
	vec3 rock_a = srgb(vec3(0.42, 0.40, 0.39));
	vec3 rock_b = srgb(vec3(0.56, 0.52, 0.47));
	vec3 rock = mix(rock_a, rock_b, fbm(vec2(world_pos.x + world_pos.z, world_pos.y * 3.0) * 0.45));
	vec3 soil = srgb(vec3(0.62, 0.48, 0.33)) * mix(0.82, 1.08, fine);

	vec3 color = mix(grass, rock, smoothstep(0.34, 0.5, slope + (grain - 0.5) * 0.14));
	color = mix(color, soil, smoothstep(0.25, 0.65, path + (fine - 0.5) * 0.45));

	// Earth layers revealed by digging: depth is measured from the original surface.
	float depth = dig + (grain - 0.5) * 1.5 + (fine - 0.5) * 0.5;
	vec3 topsoil = srgb(vec3(0.33, 0.23, 0.17));
	vec3 clay = srgb(vec3(0.70, 0.49, 0.28));
	vec3 stone = srgb(vec3(0.53, 0.50, 0.47));
	vec3 layers = mix(topsoil, clay, smoothstep(0.9, 1.7, depth));
	layers = mix(layers, stone, smoothstep(4.6, 6.0, depth));
	layers *= mix(0.82, 1.1, fine);
	color = mix(color, layers, smoothstep(0.1, 0.42, dig));

	// Wet sand and pebbles around the water, darker below the waterline.
	float above = world_pos.y - water_level;
	vec3 sand = srgb(vec3(0.66, 0.57, 0.42)) * mix(0.78, 1.05, fine);
	float undug = 1.0 - smoothstep(0.05, 0.4, dig);
	float shore = (1.0 - smoothstep(0.25, 1.1 + grain * 0.8, above)) * undug;
	color = mix(color, sand, shore);
	color *= mix(1.0, mix(0.72, 1.0, smoothstep(-1.5, 0.15, above)), undug);

	// Distant hills fade into the air.
	float haze = smoothstep(190.0, 720.0, length(world_pos.xz));
	color = mix(color, haze_color, haze * 0.97);

	ALBEDO = color * mix(sun_light_at(world_pos, TIME), 1.0, haze);
	if (range_on > 0.5) {
		vec4 overlay = range_overlay(world_pos);
		ALBEDO = mix(ALBEDO, overlay.rgb, overlay.a);
		EMISSION = overlay.rgb * overlay.a * 0.3;
	}
	ROUGHNESS = 0.92;
	SPECULAR = 0.2;
	AO = 1.0;
}
