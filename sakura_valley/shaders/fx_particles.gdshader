shader_type spatial;
// Battle effects. Each multimesh instance is one particle, and its whole life is worked out here
// from what it was born with, so the script only writes a particle once, when it is spawned.
//
// Instance layout (written by scripts/fx.gd):
//   MODEL_MATRIX[0].xyz  start size, end size, life in seconds
//   MODEL_MATRIX[1].xyz  gravity, drag, kind
//   MODEL_MATRIX[2].xyz  spin, stretch, glow
//   MODEL_MATRIX[3].xyz  start position
//   INSTANCE_CUSTOM      velocity xyz, birth time
//   COLOR                linear colour, peak opacity
// Kinds: 0 puff, 1 glow, 2 streak, 3 ground ring, 4 chunk, 5 beam, 6 petal.
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, skip_vertex_transform, shadows_disabled;

uniform float fx_time = 0.0;
uniform vec3 sun_dir = vec3(0.45, 0.8, 0.35);
// Metres over which a particle fades where it touches the ground, so puffs never show a hard cut.
uniform float soft_distance = 1.6;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;

varying vec4 v_color;
varying vec2 v_uv;
varying float v_kind;
varying float v_t;
varying float v_glow;
varying vec3 v_sun;
varying float v_seed;

float hash(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

vec2 rotate(vec2 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

void vertex() {
	vec3 sizes = MODEL_MATRIX[0].xyz;
	vec3 motion = MODEL_MATRIX[1].xyz;
	vec3 look = MODEL_MATRIX[2].xyz;
	vec3 start = MODEL_MATRIX[3].xyz;
	vec3 velocity = INSTANCE_CUSTOM.xyz;
	float birth = INSTANCE_CUSTOM.w;
	float life = max(sizes.z, 0.001);
	float age = fx_time - birth;
	float t = age / life;
	int kind = int(motion.z + 0.5);
	v_color = COLOR;
	v_uv = UV;
	v_kind = motion.z;
	v_t = t;
	v_glow = look.z;
	v_seed = hash(birth * 7.31 + start.x * 0.37 + start.z * 0.11);
	v_sun = normalize((VIEW_MATRIX * vec4(sun_dir, 0.0)).xyz);
	if (t < 0.0 || t > 1.0 || COLOR.a <= 0.0) {
		// Dead or not yet born: fold the quad away behind the camera.
		VERTEX = vec3(0.0, 0.0, 10.0);
	} else {
		float drag = motion.y;
		float gravity = motion.x;
		float slow = drag > 0.001 ? (1.0 - exp(-drag * age)) / drag : age;
		vec3 position = start + velocity * slow + vec3(0.0, -0.5 * gravity * age * age, 0.0);
		vec3 now_velocity = velocity * exp(-drag * age) + vec3(0.0, -gravity * age, 0.0);
		// Puffs swell fast, then slowly; everything else eases evenly.
		float grow = kind == 0 ? 1.0 - (1.0 - t) * (1.0 - t) : t;
		float size = mix(sizes.x, sizes.y, grow);
		vec2 corner = VERTEX.xy;
		vec3 center = (VIEW_MATRIX * vec4(position, 1.0)).xyz;
		if (kind == 3) {
			// A ring lying flat on the ground.
			vec3 world = position + vec3(corner.x, 0.0, corner.y) * size;
			VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
		} else if (kind == 5) {
			// A beam from the start to start + velocity, as wide as size, facing the camera.
			vec3 a = center;
			vec3 b = (VIEW_MATRIX * vec4(start + velocity, 1.0)).xyz;
			vec3 along = b - a;
			vec3 side = normalize(cross(along, a + along * 0.5));
			VERTEX = mix(a, b, corner.x + 0.5) + side * corner.y * size;
		} else if (kind == 2) {
			// A spark stretched along the way it is flying.
			vec2 screen = (VIEW_MATRIX * vec4(now_velocity, 0.0)).xy;
			float speed = length(screen);
			vec2 dir = speed > 0.001 ? screen / speed : vec2(1.0, 0.0);
			float length_m = size + look.y * speed;
			vec2 offset = dir * corner.x * length_m + vec2(-dir.y, dir.x) * corner.y * size * 0.45;
			VERTEX = center + vec3(offset, 0.0);
		} else {
			float spin = look.x * age + v_seed * 6.2832;
			// Chunks and petals shrink away at the end instead of fading.
			if (kind == 4 || kind == 6) {
				size *= 1.0 - pow(t, 4.0);
			}
			vec2 offset = rotate(corner * size, spin);
			if (kind == 6) {
				// Petals flutter: they flatten and widen as they turn.
				offset.x *= 0.55 + 0.45 * sin(age * 9.0 + v_seed * 20.0);
			}
			VERTEX = center + vec3(offset, 0.0);
		}
	}
}

void fragment() {
	int kind = int(v_kind + 0.5);
	// Centred quad coordinates with +y up the screen (UV runs downward).
	vec2 p = vec2(v_uv.x * 2.0 - 1.0, 1.0 - v_uv.y * 2.0);
	float r = length(p);
	float t = clamp(v_t, 0.0, 1.0);
	vec3 color = v_color.rgb;
	float alpha = 0.0;
	bool additive = false;
	if (kind == 0) {
		// A cotton-ball puff, lit from the sun's side, that wears away from its thin edges as it ages.
		float angle = atan(p.y, p.x);
		float lumpy = r * (1.0 + 0.1 * sin(angle * 3.0 + v_seed * 30.0) + 0.07 * sin(angle * 5.0 + v_seed * 11.0));
		float body = 1.0 - lumpy;
		float grain = sin(p.x * 7.0 + v_seed * 40.0) * sin(p.y * 6.0 - v_seed * 25.0) * 0.12;
		float wear = pow(t, 1.6) * 0.95;
		alpha = smoothstep(wear, wear + 0.12, body + grain * t);
		// Lit like a ball: bright on the sun's side, a cool shade underneath, a soft rim of light.
		vec3 normal = normalize(vec3(p, sqrt(max(1.0 - r * r, 0.0))));
		float light = smoothstep(-0.25, 0.75, dot(normal, v_sun));
		float under = smoothstep(0.2, -0.9, p.y);
		// Each puff gets its own shade, so a cloud of them reads as separate balls.
		color *= mix(vec3(0.58, 0.6, 0.68), vec3(1.12, 1.08, 1.0), light) * (1.0 - 0.28 * under) * mix(0.84, 1.06, v_seed);
		color += vec3(0.08) * smoothstep(0.55, 0.95, r) * light;
		alpha *= smoothstep(0.0, 0.06, t);
	} else if (kind == 1) {
		additive = true;
		alpha = exp(-r * r * 4.5) * (1.0 - t) * (1.0 - t);
	} else if (kind == 2) {
		additive = true;
		float across = abs(p.y);
		alpha = (1.0 - smoothstep(0.3, 1.0, across)) * (1.0 - smoothstep(0.6, 1.0, abs(p.x))) * (1.0 - t);
	} else if (kind == 3) {
		// An expanding ring that thins as it spreads.
		float width = mix(0.45, 0.12, t);
		float band = smoothstep(1.0 - width, 1.0 - width * 0.5, r) * (1.0 - smoothstep(0.92, 1.0, r));
		alpha = band * (1.0 - t) * (1.0 - t);
	} else if (kind == 4) {
		// A small solid chip with a lit and a shaded half.
		alpha = 1.0 - smoothstep(0.8, 0.95, max(abs(p.x), abs(p.y * 1.25)));
		color *= p.y > 0.0 ? 1.1 : 0.72;
	} else if (kind == 5) {
		additive = true;
		float across = abs(p.y);
		alpha = (1.0 - smoothstep(0.0, 1.0, across)) * (1.0 - t) * smoothstep(0.0, 0.25, v_uv.x + 0.2 - t * 0.2);
	} else {
		// A petal: a pointed oval with a paler middle.
		vec2 q = vec2(p.x, p.y * 1.7);
		float edge = length(q) + abs(p.y) * 0.25;
		alpha = 1.0 - smoothstep(0.75, 0.95, edge);
		color *= mix(1.15, 0.9, edge);
	}
	alpha *= v_color.a;
	// Fade where the particle meets the ground.
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_z = -scene.z / scene.w;
	alpha *= clamp((scene_z + VERTEX.z) / soft_distance, 0.0, 1.0);
	if (additive) {
		ALBEDO = color * v_glow * alpha;
		ALPHA = 0.0;
	} else {
		ALBEDO = color * alpha;
		ALPHA = alpha;
	}
}
