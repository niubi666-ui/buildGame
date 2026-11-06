shader_type spatial;
// Opaque body inside each canopy lump. It is lit like the leaves, so gaps read as more canopy.
render_mode unshaded, shadows_disabled;

#include "res://shaders/canopy_light.gdshaderinc"

varying vec3 tint;

void vertex() {
	vec3 normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
	tint = COLOR.rgb * canopy_light(normal, MODEL_MATRIX[3].xyz, TIME);
}

void fragment() {
	ALBEDO = tint;
}
