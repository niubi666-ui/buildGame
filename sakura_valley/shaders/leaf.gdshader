shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

#include "res://shaders/canopy_light.gdshaderinc"

uniform float wind_strength = 0.05;

varying vec3 leaf_color;

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	VERTEX.xy += vec2(sin(TIME * 1.7 + root.x * 1.3), cos(TIME * 1.3 + root.z * 1.1)) * wind_strength * 2.0;
	// MODEL_MATRIX includes this leaf's own rotation. flora.gd stores the canopy direction
	// with that rotation undone, so the result is the canopy direction in world space.
	vec3 normal = normalize(mat3(MODEL_MATRIX) * INSTANCE_CUSTOM.xyz);
	// COLOR combines this leaf's tint with the mesh's base-to-tip shading.
	leaf_color = COLOR.rgb * 1.25 * canopy_light(normal, root, TIME);
}

void fragment() {
	ALBEDO = leaf_color;
}
