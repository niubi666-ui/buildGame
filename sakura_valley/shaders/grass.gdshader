shader_type spatial;
render_mode cull_disabled, diffuse_burley, world_vertex_coords;

#include "res://shaders/meadow.gdshaderinc"
#include "res://shaders/terrain_state.gdshaderinc"
#include "res://shaders/sun_light.gdshaderinc"
#include "res://shaders/range_overlay.gdshaderinc"

uniform float wind_strength = 0.16;
uniform float water_level = 2.0;

varying vec3 tint;
varying vec3 base_color;
varying vec3 ground_normal;
varying float blade_height;
varying float petal_tint;
varying float sun_patch;
varying vec4 overlay;

void vertex() {
	petal_tint = INSTANCE_CUSTOM.w;
	vec3 root = MODEL_MATRIX[3].xyz;
	vec4 state = sample_state(root.xz);
	sun_patch = sun_light_at(vec3(root.x, state.r, root.z), TIME);
	overlay = range_on > 0.5 ? range_overlay(vec3(root.x, state.r, root.z)) : vec4(0.0);
	vec3 normal = state_normal(state);
	blade_height = UV.y;
	base_color = meadow_color(root.xz);
	tint = COLOR.rgb;
	// Tufts exist everywhere, and the ground decides which ones show, so filled land regrows.
	bool grows = state.r >= water_level + 0.5 && normal.y >= 0.64 && state.g <= 0.28 && INSTANCE_CUSTOM.x < 0.42;
	if (grows) {
		float gust = sin(TIME * 0.9 + root.x * 0.09 + root.z * 0.07) * 0.6 + sin(TIME * 2.3 + root.x * 0.5) * 0.25;
		VERTEX.xz += vec2(0.8, 0.45) * (gust + 0.35) * wind_strength * UV.y * UV.y;
		VERTEX.y += state.r - 0.03;
	} else {
		VERTEX = vec3(root.x, -500.0, root.z);
	}
	// Lighting uses the ground normal, so blades shade softly as one surface.
	ground_normal = (VIEW_MATRIX * vec4(normal, 0.0)).xyz;
}

void fragment() {
	vec3 root_color = base_color * 0.5;
	vec3 tip_color = mix(base_color * tint * 1.04, vec3(0.82, 0.42, 0.5), petal_tint);
	ALBEDO = mix(root_color, tip_color, smoothstep(0.0, 0.85, blade_height)) * sun_patch;
	ALBEDO = mix(ALBEDO, overlay.rgb, overlay.a);
	EMISSION = overlay.rgb * overlay.a * 0.3;
	NORMAL = normalize(ground_normal);
	ROUGHNESS = 0.82;
	SPECULAR = 0.15;
	BACKLIGHT = vec3(0.2, 0.22, 0.08) * blade_height;
	AO = mix(0.55, 1.0, blade_height);
	AO_LIGHT_AFFECT = 0.5;
}
