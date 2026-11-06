// Tower sailcloth, flags and painted bands: the parts an upgrade repaints.
// Each mesh surface was modelled either cream (baked_accent off) or in the accent colour (on).
// Cloth panels that follow the stripe pattern carry UV x = 1 + u * columns, y = 1 + v; everything
// else has UV (0, 0) and keeps its modelled colour. See canvas() in
// art/models/towers/build_windmill_towers.py, which draws the same patterns for the Blender previews.
shader_type spatial;
render_mode diffuse_burley, world_vertex_coords;

#include "res://shaders/common.gdshaderinc"
#include "res://shaders/sun_light.gdshaderinc"

uniform vec3 cloth : source_color = vec3(0.89, 0.85, 0.75);
uniform vec3 accent : source_color = vec3(0.5, 0.67, 0.85);
// 0: stripes as modelled. 1: vertical stripes, every second column. 2: dyed hem with one band above.
uniform int pattern = 0;
uniform bool baked_accent = false;
uniform float variation = 0.08;
uniform float noise_scale = 3.0;
uniform float roughness = 0.9;

varying vec3 world_pos;
varying vec3 tint;

void vertex() {
	world_pos = VERTEX;
	tint = COLOR.rgb;
}

void fragment() {
	bool use_accent = baked_accent;
	if (pattern > 0 && UV.x >= 0.5) {
		float v = UV.y - 1.0;
		if (pattern == 1) {
			use_accent = mod(floor(UV.x - 1.0), 2.0) > 0.5;
		} else {
			use_accent = v < 0.4 || (v >= 0.55 && v <= 0.68);
		}
	}
	float n = fbm(vec2(world_pos.x + world_pos.z * 0.7, world_pos.y + world_pos.z * 0.3) * noise_scale);
	vec3 base = use_accent ? accent : cloth;
	ALBEDO = base * tint * (1.0 + (n - 0.5) * 2.0 * variation) * sun_light_at(world_pos, TIME);
	ROUGHNESS = roughness;
	SPECULAR = 0.2;
}
