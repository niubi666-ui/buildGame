// Soft light for tree canopies, worked out per vertex from the canopy's overall shape.
// Each tree reads as one rounded mass, with no per-leaf shading, shadow speckle or black gaps.
#include "res://shaders/sun_light.gdshaderinc"

vec3 canopy_light(vec3 normal, vec3 world, float t) {
	float wrap = clamp((dot(normal, SUN_DIR) + 0.6) / 1.6, 0.0, 1.0);
	vec3 ambient = mix(vec3(0.36, 0.27, 0.32), vec3(0.46, 0.44, 0.48), normal.y * 0.5 + 0.5);
	vec3 sun = vec3(1.0, 0.84, 0.62) * 0.82 * wrap * wrap;
	// Cloud gaps only touch trees gently, so a tree in cloud shade never turns dark.
	float cloud = mix(0.84, 1.03, sun_gap(sun_ground_point(world), t));
	return (ambient + sun) * cloud;
}
