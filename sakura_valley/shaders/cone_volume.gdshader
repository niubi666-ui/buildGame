shader_type spatial;
// The cone in the air. Its outline is strongest where the surface turns edge-on to the camera.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 tint : source_color = vec3(1.0, 0.82, 0.3);

void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	ALBEDO = tint;
	ALPHA = mix(0.2, 0.02, smoothstep(0.0, 0.3, facing));
}
