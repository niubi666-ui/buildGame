extends MultiMeshInstance3D
## Battle effects: muzzle flashes, shot trails, impacts, burning embers and the poof when an enemy falls.
## Every particle is one instance in this multimesh. shaders/fx_particles.gdshader works out its whole
## flight from how it was born, so the script only writes each particle once.
## What each effect looks like is in data/effects.json.

const KINDS := {"puff": 0, "glow": 1, "streak": 2, "ring": 3, "chunk": 4, "beam": 5, "petal": 6}
const CONFIG_PATH := "res://data/effects.json"

var config := {}
var recipes := {}
var styles := {}
## Tower id to its style name ("cannon", "catapult" or "sniper"). Unknown ids use "cannon".
var tower_styles := {}
## Battle seconds shown so far. Particles age with the battle, so 8x speed plays them 8x faster.
var clock := 0.0
var pool := 8192
var max_new := 900
## Everything grows or speeds up by these, from data/effects.json.
var size_scale := 1.0
var speed_scale := 1.0
var next := 0
var made_this_frame := 0
var rng := RandomNumberGenerator.new()
var shader_material: ShaderMaterial
## Recipes with their colours already turned into linear Color values.
var _parsed := {}


func _init() -> void:
	config = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	pool = int(config.get("pool", 8192))
	max_new = int(config.get("max_new_per_frame", 900))
	size_scale = float(config.get("size_scale", 1.0))
	speed_scale = float(config.get("speed_scale", 1.0))
	styles = config["styles"]
	for key: String in config["recipes"]:
		_parsed[key] = _parse_recipe(config["recipes"][key])
	rng.randomize()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	shader_material = ShaderMaterial.new()
	shader_material.shader = load("res://shaders/fx_particles.gdshader")
	quad.material = shader_material
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = pool
	# The particles move on the GPU, so the bounds cannot come from their stored transforms.
	var bounds := AABB(Vector3(-3000.0, -500.0, -3000.0), Vector3(6000.0, 1500.0, 6000.0))
	mm.custom_aabb = bounds
	multimesh = mm
	custom_aabb = bounds
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _ready() -> void:
	var sun := _find_sun(get_tree().root)
	if sun:
		shader_material.set_shader_parameter("sun_dir", sun.global_transform.basis.z.normalized())


func _find_sun(node: Node) -> DirectionalLight3D:
	if node is DirectionalLight3D:
		return node
	for child in node.get_children():
		var found := _find_sun(child)
		if found:
			return found
	return null


static func _color(text: String) -> Color:
	return Color(text).srgb_to_linear()


func _parse_recipe(list: Array) -> Array:
	var out := []
	for item: Dictionary in list:
		var emitter := item.duplicate()
		emitter["kind_id"] = KINDS.get(String(item["kind"]), 0)
		var colors: Array = item["color"] if item.get("color") is Array else [item.get("color", "#ffffff")]
		var parsed: Array = []
		for c: String in colors:
			parsed.append(null if c == "tint" else _color(c))
		emitter["colors"] = parsed
		out.append(emitter)
	return out


## Moves the effects on by dt seconds of battle time.
func advance(dt: float) -> void:
	clock += dt
	made_this_frame = 0
	shader_material.set_shader_parameter("fx_time", clock)


func style_of(tower_id: int) -> String:
	return tower_styles.get(tower_id, "cannon")


## Plays a recipe. amount grows the counts, sizes, speeds and spread it marks as scaling.
## forward aims "forward" emitters, and to is where a beam ends.
func emit(recipe: String, at: Vector3, amount := 1.0, forward := Vector3.UP, to := Vector3.ZERO, tint := Color.WHITE) -> void:
	if not _parsed.has(recipe):
		return
	for e: Dictionary in _parsed[recipe]:
		var count: float = float(e.get("count", 1)) * (amount if e.get("count_scale", false) else 1.0)
		var whole := int(count)
		if rng.randf() < count - float(whole):
			whole += 1
		for n in whole:
			_spawn(e, at, amount, forward, to, tint)


func _spawn(e: Dictionary, at: Vector3, amount: float, forward: Vector3, to: Vector3, tint: Color) -> void:
	if made_this_frame >= max_new:
		return
	made_this_frame += 1
	var kind: int = e["kind_id"]
	var sizes: Array = e.get("size", [1.0, 1.0])
	var size_by := (amount if e.get("scale_size", false) else 1.0) * size_scale
	var jitter := 1.0 + rng.randf_range(-1.0, 1.0) * float(e.get("size_jitter", 0.15))
	var size0 := float(sizes[0]) * size_by * jitter
	var size1 := float(sizes[1]) * size_by * jitter
	var lives: Array = e.get("life", [1.0, 1.0])
	var life := rng.randf_range(float(lives[0]), float(lives[1]))
	var speeds: Array = e.get("speed", [0.0, 0.0])
	var speed := rng.randf_range(float(speeds[0]), float(speeds[1])) * (amount if e.get("scale_speed", false) else 1.0) * speed_scale
	var dir := _direction(String(e.get("dir", "none")), forward, float(e.get("cone", 30.0)))
	var velocity := dir * speed + Vector3.UP * float(e.get("lift", 0.0)) * (1.0 if kind != 3 else 0.0)
	var start := at
	var spread := float(e.get("spread", 0.0)) * amount * size_scale
	if spread > 0.0:
		var flat := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * spread
		start += Vector3(flat.x, rng.randf() * spread * 0.3, flat.y)
	if kind == 3:
		# Rings sit just above the ground they spread over.
		start.y += float(e.get("lift", 0.2))
	if kind == 5:
		velocity = to - at
	var colors: Array = e["colors"]
	var color = colors[rng.randi() % colors.size()]
	var c: Color = tint if color == null else color
	c.a = float(e.get("alpha", 1.0))
	var spin := float(e.get("spin", 0.0)) * (1.0 if rng.randf() < 0.5 else -1.0) * rng.randf_range(0.6, 1.0)
	var data := Transform3D(
		Basis(Vector3(size0, size1, life), Vector3(float(e.get("gravity", 0.0)), float(e.get("drag", 0.0)), float(kind)),
			Vector3(spin, float(e.get("stretch", 0.0)), float(e.get("glow", 1.0)))),
		start)
	multimesh.set_instance_transform(next, data)
	multimesh.set_instance_color(next, c)
	multimesh.set_instance_custom_data(next, Color(velocity.x, velocity.y, velocity.z, clock))
	next = (next + 1) % pool


func _direction(mode: String, forward: Vector3, cone_degrees: float) -> Vector3:
	match mode:
		"up":
			# Mostly upward, leaning out in every direction.
			var a := rng.randf() * TAU
			var lean := rng.randf_range(0.15, 0.85)
			return Vector3(cos(a) * lean, 1.0, sin(a) * lean).normalized()
		"sphere":
			return Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)).normalized()
		"flat":
			var a := rng.randf() * TAU
			return Vector3(cos(a), rng.randf_range(0.0, 0.15), sin(a)).normalized()
		"forward":
			var f := forward.normalized()
			var side := f.cross(Vector3.UP if absf(f.y) < 0.95 else Vector3.RIGHT).normalized()
			var up := side.cross(f)
			var angle := deg_to_rad(cone_degrees) * sqrt(rng.randf())
			var turn := rng.randf() * TAU
			return (f * cos(angle) + (side * cos(turn) + up * sin(turn)) * sin(angle)).normalized()
	return Vector3.ZERO


## A tower has fired: its flash and smoke at the muzzle, or the beam of a sniper's shot.
func launched(tower_id: int, from: Vector3, target: Vector3) -> void:
	var style: Dictionary = styles.get(style_of(tower_id), styles["cannon"])
	emit(String(style["launch"]), from, 1.0, (target - from).normalized(), target)


## A shot has landed. flags: 1 it sets the ground burning, 2 it slows.
func impact(tower_id: int, at: Vector3, radius: float, flags: int) -> void:
	var style: Dictionary = styles.get(style_of(tower_id), styles["cannon"])
	var amount := clampf(maxf(radius, 1.0) / float(style["impact_radius"]), 0.5, 2.5)
	emit(String(style["impact"]), at, amount)
	if flags & 1:
		emit(String(config["on_fire_impact"]), at, amount)
	if flags & 2:
		emit(String(config["on_slow_impact"]), at, amount)


func died(at: Vector3, tint: Color) -> void:
	emit(String(config["death"]), at + Vector3.UP * 0.8, 1.0, Vector3.UP, Vector3.ZERO, tint)


func upgraded(at: Vector3) -> void:
	emit(String(config["upgrade"]), at)


## Smoke and sparks behind every shot in flight. buffer is a shots or stones buffer from the core.
func trail(buffer: PackedFloat32Array, dt: float) -> void:
	if dt <= 0.0:
		return
	for o in range(0, buffer.size(), 20):
		if buffer[o + 15] <= 0.0:
			continue
		var style: Dictionary = styles.get(style_of(int(buffer[o + 16])), styles["cannon"])
		var rate: float = style["trail_rate"]
		if rate <= 0.0:
			continue
		var at := Vector3(buffer[o + 3], buffer[o + 7], buffer[o + 11])
		var back := -Vector3(buffer[o + 2], buffer[o + 6], buffer[o + 10])
		# Spread this frame's puffs along the stretch the shot just covered.
		var reach := float(style["trail_speed"]) * dt
		var count := rate * dt
		var whole := int(count)
		if rng.randf() < count - float(whole):
			whole += 1
		for n in whole:
			emit(String(style["trail"]), at + back * reach * rng.randf())


## Embers drifting up from each burning patch. state is the core's fires list, five floats each.
func embers(state: PackedFloat32Array, dt: float) -> void:
	var setting: Dictionary = config["fire_embers"]
	var rate := float(setting["per_second"]) * dt
	for o in range(0, state.size(), 5):
		var radius := state[o + 3]
		var count := rate * radius / 6.0
		var whole := int(count)
		if rng.randf() < count - float(whole):
			whole += 1
		for n in whole:
			emit(String(setting["recipe"]), Vector3(state[o], state[o + 1] + 0.3, state[o + 2]), radius / 6.0)


## How a tower's gun moves when it fires, from data/effects.json.
func recoil(style: String) -> Dictionary:
	return config["recoil"].get(style, {})


## Clears every particle, for a fresh level or test.
func clear() -> void:
	for n in pool:
		multimesh.set_instance_color(n, Color(0, 0, 0, 0))
