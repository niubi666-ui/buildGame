shader_type spatial;
// A soft sea of clouds below floating islands. Two layers of billows drift past each other.
render_mode diffuse_burley, specular_disabled, world_vertex_coords;

uniform vec3 light_color : source_color = vec3(0.98, 0.97, 0.95);
uniform vec3 shade_color : source_color = vec3(0.7, 0.77, 0.86);
uniform sampler2D billow_map : filter_linear_mipmap, repeat_enable;
uniform sampler2D billow_normals : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float scale = 0.0035;
uniform float drift = 1.0;
uniform float billow_height = 4.0;

varying vec3 world_pos;

vec2 layer_a(vec2 xz) {
	return xz * scale + vec2(TIME * drift * 0.0016, TIME * drift * 0.0006);
}

vec2 layer_b(vec2 xz) {
	return xz * scale * 2.3 + vec2(-TIME * drift * 0.0011, TIME * drift * 0.0019) + vec2(0.37, 0.61);
}

void vertex() {
	float b = textureLod(billow_map, layer_a(VERTEX.xz), 0.0).r;
	VERTEX.y += (b - 0.5) * billow_height;
	world_pos = VERTEX;
}

void fragment() {
	float a = texture(billow_map, layer_a(world_pos.xz)).r;
	float b = texture(billow_map, layer_b(world_pos.xz)).r;
	float puff = a * 0.65 + b * 0.35;
	float lit = smoothstep(0.3, 0.75, puff);
	ALBEDO = mix(shade_color, light_color, lit);
	ROUGHNESS = 1.0;
	vec3 na = texture(billow_normals, layer_a(world_pos.xz)).xyz * 2.0 - 1.0;
	vec3 nb = texture(billow_normals, layer_b(world_pos.xz)).xyz * 2.0 - 1.0;
	vec3 n = normalize(vec3(na.x + nb.x * 0.6, 1.0, na.y + nb.y * 0.6));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	// Cloud tops glow a little from the light passing through them.
	EMISSION = light_color * (0.08 + 0.1 * lit);
}
