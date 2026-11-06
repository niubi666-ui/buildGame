extends Node
## Enemy waves and route preview. Planning and movement live in native/path_core.cpp.
## The core is kept in an untyped variable, because the C++ class only supports dynamic calls.

const Props = preload("res://scripts/props.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Fx = preload("res://scripts/fx.gd")

## Sent when a wave ends, before the route is worked out again.
signal battle_ended
## Sent after a replan with how each gate's time changed: gate name, seconds, and old and new route words.
signal plan_changed(changes: Array)
## Sent when the level has been won or lost.
signal level_finished(won: bool)
## Sent each time a tower fires, so its gun can kick back.
signal tower_fired(tower_id: int)

enum Phase { BUILD, BATTLE }
enum { MODE_WALK, MODE_CLIMB, MODE_BOAT, MODE_BRIDGE, MODE_GOAL, MODE_BUILT_BRIDGE, MODE_TUNNEL }
enum { ALLOW_CLIMB = 1, ALLOW_BOAT = 2, ALLOW_BRIDGE = 4 }

## Size of the plain test wave that the automated tests send.
const WAVE_SIZE := 60
const PLANK_LENGTH := 0.9
const MAX_SHOTS := 200
## Must match MAX_FIRES in native/path_core.cpp.
const MAX_FIRES := 48
const SPEEDS: Array[float] = [1.0, 1.5, 2.0, 4.0, 8.0]
const SPEED_NAMES: Array[String] = ["1x", "1.5x", "2x", "4x", "8x"]
const ROUTE_COLORS := {
	MODE_WALK: Kit.ROUTE_WALK,
	MODE_CLIMB: Kit.ROUTE_CLIMB,
	MODE_BOAT: Kit.ROUTE_BOAT,
	MODE_BRIDGE: Kit.ROUTE_BRIDGE,
	MODE_BUILT_BRIDGE: Kit.ROUTE_BUILT,
	MODE_TUNNEL: Kit.ROUTE_TUNNEL,
}

var core
var terrain
var brush: Node
var level := {}
var enemy_specs := {}
## Enemy type id to its index in the C++ core.
var type_index := {}
## Each gate: id, name, point.
var gates: Array[Dictionary] = []
var route_choices: Array = []
var phase := Phase.BUILD
var wave := 0
## The first gate, used by the automated tests.
var spawn_point := Vector2.ZERO
var home := Vector2.ZERO
var goal_radius := 0.0
## Which types the next wave brings, most common first.
var wave_types: Array[int] = []
var plan := {}
## One entry per gate. Each has name, label, time and alternatives.
var gate_plans: Array[Dictionary] = []
## Counts up each time the plan changes, so the interface knows when to redraw it.
var plan_version := 0
## Slower comparisons, worked out one per frame after a replan.
var option_jobs: Array[Callable] = []
var planned_wave := -1
var option_frame := false
var option_results := []
var options_version := 0
## How many enemies the current wave started with.
var wave_total := 0
var home_hp := 0
var home_hp_max := 0
var last_arrived := 0
var last_earned := 0.0
var earned_this_wave := 0
## "won" or "lost" once the level is over.
var outcome := ""
## Particle effects for shots, impacts and falling enemies.
var fx: Fx
## Each enemy type index's colour, for the scraps it leaves when it falls.
var type_colors: Array[Color] = []
## Burning ground left by fire shells, one soft glowing dome per patch.
var fire_layer: MultiMeshInstance3D
var fire_clock := 0.0
var speed_index := 0
var last_solve_ms := 0.0
var last_step_ms := 0.0
## Game speed. It scales only the battle, so the camera and water keep their normal pace.
var speed := 1.0
## Seconds of battle simulated so far.
var sim_time := 0.0
var route_points := PackedFloat32Array()

var figures: MultiMeshInstance3D
var boats: MultiMeshInstance3D
var arrows: MultiMeshInstance3D
var stones: MultiMeshInstance3D
var route: MeshInstance3D
var route_material: StandardMaterial3D
var bridge_root: Node3D
var bridge_nodes := {}


func setup(data, brush_node: Node, level_config: Dictionary, enemy_config: Dictionary, routing: Dictionary) -> void:
	terrain = data
	brush = brush_node
	level = level_config
	enemy_specs = enemy_config
	core = ClassDB.instantiate("PathCore")
	if core == null:
		push_error("PathCore is missing: build native/build.cmd, then run the project's import once.")
		set_process(false)
		return
	core.configure(routing["min_gap_depth"], routing["max_span"], routing["tunnel_speed"])
	# Levels floating above a sea of clouds: ground sunk below this is open sky.
	core.set_void_level(float(level["map"].get("void_level", -1000.0)))
	var index := 0
	for id: String in enemy_specs:
		type_index[id] = index
		type_colors.append(Color(String(enemy_specs[id]["color"])).srgb_to_linear())
		core.set_type(index, _type_numbers(enemy_specs[id]))
		index += 1
	var flat := PackedFloat32Array()
	for gate: Dictionary in level["gates"]:
		var point := Vector2(gate["x"], gate["z"])
		gates.append({"id": gate["id"], "name": gate["name"], "point": point})
		flat.append(point.x)
		flat.append(point.y)
	core.set_gates(flat, flat.size())
	spawn_point = gates[0]["point"]
	route_choices = level["map"].get("route_choices", [])
	home = terrain.home_center()
	goal_radius = terrain.shape.goal_radius()
	home_hp_max = int(level.get("home_hp", 0))
	home_hp = home_hp_max
	_build_units()
	_build_route()
	brush.terrain_changed.connect(replan)
	replan()


static func _type_numbers(spec: Dictionary) -> PackedFloat32Array:
	var color := Color(String(spec["color"])).srgb_to_linear()
	return PackedFloat32Array([
		spec["walk_speed"], spec["uphill_penalty"], spec["climb_speed"], spec["climb_slope"], spec["boat_speed"], spec["embark_time"],
		spec["bridge_time"], spec["crew"], spec["hp"], spec["reward"], color.r, color.g, color.b, spec["scale"],
	])


## The wave that comes next. An empty result means there are none left.
func next_wave() -> Dictionary:
	var waves: Array = level["waves"]
	if wave < waves.size():
		return waves[wave]
	return waves[waves.size() - 1] if level.get("endless", false) else {}


func total_waves() -> int:
	return level["waves"].size()


func wave_count(spec: Dictionary) -> int:
	var total := 0
	for group: Dictionary in spec.get("groups", []):
		total += int(group["count"])
	return total


## The next wave added up by type, most common first: id, name, trait, color, count.
func wave_summary(spec: Dictionary) -> Array[Dictionary]:
	var counts := {}
	for group: Dictionary in spec.get("groups", []):
		counts[group["type"]] = int(counts.get(group["type"], 0)) + int(group["count"])
	var ids: Array = counts.keys()
	ids.sort_custom(func(a: String, b: String) -> bool: return counts[a] > counts[b])
	var out: Array[Dictionary] = []
	for id: String in ids:
		var type_spec: Dictionary = enemy_specs[id]
		out.append({"id": id, "name": type_spec["name"], "trait": type_spec["trait"], "color": Color(String(type_spec["color"])), "count": counts[id]})
	return out


func _choose_wave_types() -> void:
	wave_types.clear()
	for entry: Dictionary in wave_summary(next_wave()):
		wave_types.append(type_index[entry["id"]])
	if wave_types.is_empty():
		wave_types.append(0)
	var flat := PackedFloat32Array()
	for type in wave_types:
		flat.append(float(type))
	core.set_active_types(flat, flat.size())


func _build_units() -> void:
	var whole_map := AABB(Vector3(-200.0, -60.0, -200.0), Vector3(400.0, 300.0, 400.0))
	var body := CapsuleMesh.new()
	body.radius = 0.36
	body.height = 1.7
	body.radial_segments = 6
	body.rings = 1
	# Each enemy's color comes from its type, through the instance color.
	body.material = Props.solid(Color.WHITE, 0.0)
	figures = _unit_layer(body, whole_map)
	var hull := BoxMesh.new()
	hull.size = Vector3(1.2, 0.4, 2.6)
	hull.material = Props.solid(Props.TIMBER, 0.2, 4.0)
	boats = _unit_layer(hull, whole_map)
	var arrow_material := StandardMaterial3D.new()
	arrow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow_material.albedo_color = Color(1.0, 0.93, 0.7)
	var arrow := BoxMesh.new()
	arrow.size = Vector3(0.28, 0.28, 3.0)
	arrow.material = arrow_material
	arrows = _unit_layer(arrow, whole_map)
	arrows.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arrows.multimesh.instance_count = MAX_SHOTS
	# Catapult stones: a lumpy grey rock, tumbling as it flies.
	var stone := SphereMesh.new()
	stone.radius = 1.0
	stone.height = 1.7
	stone.radial_segments = 7
	stone.rings = 3
	stone.material = Props.solid(Props.STONE, 0.2, 2.0)
	stones = _unit_layer(stone, whole_map)
	stones.multimesh.instance_count = MAX_SHOTS
	var fire_material := StandardMaterial3D.new()
	fire_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fire_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fire_material.vertex_color_use_as_albedo = true
	var fire_mesh := SphereMesh.new()
	fire_mesh.radius = 1.0
	fire_mesh.height = 2.0
	fire_mesh.radial_segments = 16
	fire_mesh.rings = 4
	fire_mesh.is_hemisphere = true
	fire_mesh.material = fire_material
	fire_layer = _unit_layer(fire_mesh, whole_map)
	fire_layer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fire_layer.multimesh.instance_count = MAX_FIRES
	fire_layer.multimesh.visible_instance_count = 0
	bridge_root = Node3D.new()
	add_child(bridge_root)
	fx = Fx.new()
	add_child(fx)


func _unit_layer(mesh: Mesh, bounds: AABB) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	var node := MultiMeshInstance3D.new()
	node.multimesh = multimesh
	node.custom_aabb = bounds
	add_child(node)
	return node


func _build_route() -> void:
	route_material = StandardMaterial3D.new()
	route_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	route_material.vertex_color_use_as_albedo = true
	route_material.vertex_color_is_srgb = true
	route_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	route_material.no_depth_test = true
	route_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	route = MeshInstance3D.new()
	route.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	route.custom_aabb = AABB(Vector3(-200.0, -60.0, -200.0), Vector3(400.0, 300.0, 400.0))
	add_child(route)


func set_speed(index: int) -> void:
	speed_index = index
	speed = SPEEDS[index]


## Gives the core the current terrain, then works out and shows the new route.
func replan() -> void:
	var begin := Time.get_ticks_usec()
	_choose_wave_types()
	core.set_terrain(terrain.heights, terrain.water_mask, terrain.RES, terrain.SIZE, terrain.WATER_LEVEL)
	core.solve(home.x, home.y, goal_radius)
	last_solve_ms = float(Time.get_ticks_usec() - begin) / 1000.0
	var old_plans := gate_plans
	gate_plans = []
	var main_type: int = wave_types[0]
	plan = _empty_plan()
	var traces: Array[PackedFloat32Array] = []
	for gate in gates:
		var point: Vector2 = gate["point"]
		var points: PackedFloat32Array = core.trace(main_type, point.x, point.y)
		traces.append(points)
		var time: float = core.cost_at(main_type, point.x, point.y)
		gate_plans.append({"name": gate["name"], "time": time, "label": terrain.shape.describe_route(points), "alternatives": []})
		_add_to_plan(plan, points)
		plan["time"] = minf(plan["time"], time)
	route_points = traces[0]
	# Other types in the wave may choose differently, and the player should see that coming.
	for type in wave_types:
		if type != main_type:
			for gate in gates:
				var point: Vector2 = gate["point"]
				traces.append(core.trace(type, point.x, point.y))
	plan_version += 1
	_draw_routes(traces)
	_sync_bridges()
	# A new wave changes the times too, but the player did not cause that.
	if planned_wave == wave:
		_report_changes(old_plans)
	planned_wave = wave
	_queue_options(main_type)


func _report_changes(old_plans: Array[Dictionary]) -> void:
	if old_plans.size() != gate_plans.size():
		return
	var changes: Array = []
	for n in gate_plans.size():
		var delta: float = gate_plans[n]["time"] - old_plans[n]["time"]
		var moved: bool = gate_plans[n]["label"] != old_plans[n]["label"]
		if absf(delta) >= 0.5 or moved:
			changes.append({"name": gate_plans[n]["name"], "delta": delta, "label": gate_plans[n]["label"], "moved": moved})
	if not changes.is_empty():
		plan_changed.emit(changes)


## Comparing routes takes one extra search each, so they run one per frame instead of all at once.
func _queue_options(type: int) -> void:
	option_results = []
	option_jobs = []
	for n in gates.size():
		option_results.append({})
	for entry: Array in [["绕路", 0], ["爬坡", ALLOW_CLIMB], ["搭桥", ALLOW_BRIDGE], ["划船", ALLOW_BOAT]]:
		option_jobs.append(_run_mask_option.bind(type, entry[0], entry[1]))
	for choice: Dictionary in route_choices:
		option_jobs.append(_run_via_option.bind(type, choice["label"], float(choice["x"]), float(choice["z"])))


func _run_mask_option(type: int, label: String, allow: int) -> void:
	var costs: PackedFloat32Array = core.option_costs(type, allow)
	for n in costs.size():
		option_results[n][label] = costs[n]


func _run_via_option(type: int, label: String, x: float, z: float) -> void:
	var costs: PackedFloat32Array = core.via_costs(type, x, z)
	for n in costs.size():
		option_results[n][label] = costs[n]


func _publish_options() -> void:
	for n in gate_plans.size():
		var best: float = gate_plans[n]["time"]
		var current: String = gate_plans[n]["label"]
		var results: Dictionary = option_results[n]
		var walk_only: float = results.get("绕路", -1.0)
		var list: Array[Dictionary] = []
		for label: String in results:
			var time: float = results[label]
			if time < 0.0 or label == current or time < best + 0.75:
				continue
			# A mode that does not beat plain walking is not really a separate choice.
			if label in ["爬坡", "搭桥", "划船"] and walk_only >= 0.0 and time >= walk_only - 0.5:
				continue
			list.append({"label": label, "time": time})
		list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["time"] < b["time"])
		gate_plans[n]["alternatives"] = list.slice(0, 3)
	options_version += 1


func _empty_plan() -> Dictionary:
	return {"walk": 0.0, "climb": 0.0, "boat": 0.0, "bridges": 0, "span": 0.0, "built": 0, "tunnels": 0, "time": INF}


func _add_to_plan(result: Dictionary, points: PackedFloat32Array) -> void:
	for n in range(0, points.size() - 4, 4):
		var from := Vector3(points[n], points[n + 1], points[n + 2])
		var to := Vector3(points[n + 4], points[n + 5], points[n + 6])
		var length := from.distance_to(to)
		match int(points[n + 3]):
			MODE_WALK:
				result["walk"] += length
			MODE_CLIMB:
				result["climb"] += length
			MODE_BOAT:
				result["boat"] += length
			MODE_BRIDGE:
				result["bridges"] += 1
				result["span"] += length
			MODE_BUILT_BRIDGE:
				result["built"] += 1
				result["walk"] += length
			MODE_TUNNEL:
				result["tunnels"] += 1


func _draw_routes(traces: Array[PackedFloat32Array]) -> void:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	for points in traces:
		for n in range(0, points.size() - 4, 4):
			var mode := int(points[n + 3])
			var index := n / 4
			# Walking shows as dashes. Anything unusual stays solid so it stands out.
			if mode == MODE_WALK and index % 5 >= 3:
				continue
			var lift := Vector3(0.0, 0.7, 0.0)
			var from := Vector3(points[n], points[n + 1], points[n + 2]) + lift
			var to := Vector3(points[n + 4], points[n + 5], points[n + 6]) + lift
			var across := (to - from).cross(Vector3.UP).normalized() * (1.3 if mode == MODE_BRIDGE or mode == MODE_TUNNEL else 0.75)
			var color: Color = ROUTE_COLORS.get(mode, ROUTE_COLORS[MODE_WALK])
			verts.append_array(PackedVector3Array([from - across, from + across, to + across, from - across, to + across, to - across]))
			for corner in 6:
				colors.append(color)
	var mesh := ArrayMesh.new()
	if not verts.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_COLOR] = colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, route_material)
	route.mesh = mesh


func start_battle() -> void:
	if phase == Phase.BATTLE or core == null or outcome != "" or brush.ground_busy:
		return
	var spec := next_wave()
	if spec.is_empty():
		return
	phase = Phase.BATTLE
	option_jobs = []
	wave += 1
	brush.end_stroke()
	brush.locked = true
	brush.clear_undo()
	route.visible = false
	core.begin_wave()
	var total := 0
	for group: Dictionary in spec["groups"]:
		var point := _gate_point(group["gate"])
		core.add_group(type_index[group["type"]], point.x, point.y, group["count"], group["interval"], group["delay"])
		total += int(group["count"])
	core.finish_wave()
	_wave_started(total)


func _gate_point(gate_id: String) -> Vector2:
	for gate in gates:
		if gate["id"] == gate_id:
			return gate["point"]
	push_error("Level file names an unknown gate: %s" % gate_id)
	return spawn_point


## A plain wave from the first gate, for the automated tests.
func spawn_wave(count: int, interval: float) -> void:
	core.begin_wave()
	core.add_group(wave_types[0], spawn_point.x, spawn_point.y, count, interval, 0.0)
	core.finish_wave()
	_wave_started(count)


func _wave_started(total: int) -> void:
	wave_total = total
	last_arrived = 0
	last_earned = 0.0
	earned_this_wave = 0
	figures.multimesh.instance_count = total
	boats.multimesh.instance_count = total


func end_battle() -> void:
	phase = Phase.BUILD
	battle_ended.emit()
	brush.locked = false
	figures.multimesh.instance_count = 0
	boats.multimesh.instance_count = 0
	arrows.multimesh.buffer = core.shots()
	for n in MAX_SHOTS:
		arrows.multimesh.set_instance_transform(n, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
		stones.multimesh.set_instance_transform(n, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
	if next_wave().is_empty():
		_finish_level(true)
		return
	route.visible = true
	replan()


func _finish_level(won: bool) -> void:
	outcome = "won" if won else "lost"
	brush.locked = true
	level_finished.emit(won)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_B:
			start_battle()
		elif event.physical_keycode >= KEY_1 and event.physical_keycode <= KEY_5:
			set_speed(int(event.physical_keycode) - KEY_1)


func _process(delta: float) -> void:
	fx.advance(delta * speed)
	if phase != Phase.BATTLE:
		fire_layer.multimesh.visible_instance_count = 0
		# Every other frame, so comparing routes never holds the frame rate down.
		option_frame = not option_frame
		if option_frame and not option_jobs.is_empty():
			option_jobs.pop_front().call()
			if option_jobs.is_empty():
				_publish_options()
		return
	if outcome != "":
		return
	var begin := Time.get_ticks_usec()
	var buffer: PackedFloat32Array = core.step(delta * speed)
	last_step_ms = float(Time.get_ticks_usec() - begin) / 1000.0
	sim_time += delta * speed
	figures.multimesh.buffer = buffer
	boats.multimesh.buffer = core.boats()
	var shot_state: PackedFloat32Array = core.shots()
	var stone_state: PackedFloat32Array = core.stones()
	arrows.multimesh.buffer = shot_state
	stones.multimesh.buffer = stone_state
	_play_effects(shot_state, stone_state, delta * speed)
	var earned: float = core.earned()
	if earned > last_earned:
		brush.money += earned - last_earned
		earned_this_wave = int(earned)
		last_earned = earned
	var arrived: int = core.arrived()
	if arrived > last_arrived:
		if home_hp_max > 0:
			home_hp = maxi(home_hp - (arrived - last_arrived), 0)
		last_arrived = arrived
	_update_fires(delta)
	_sync_bridges()
	if home_hp_max > 0 and home_hp <= 0:
		_finish_level(false)
	elif core.active() == 0:
		end_battle()


## Flashes, smoke and sparks for everything the core reports since the last frame.
func _play_effects(shot_state: PackedFloat32Array, stone_state: PackedFloat32Array, dt: float) -> void:
	var launches: PackedFloat32Array = core.take_launches()
	for o in range(0, launches.size(), 7):
		var id := int(launches[o])
		fx.launched(id, Vector3(launches[o + 1], launches[o + 2], launches[o + 3]), Vector3(launches[o + 4], launches[o + 5], launches[o + 6]))
		tower_fired.emit(id)
	var impacts: PackedFloat32Array = core.take_impacts()
	for o in range(0, impacts.size(), 6):
		fx.impact(int(impacts[o + 4]), Vector3(impacts[o], impacts[o + 1], impacts[o + 2]), impacts[o + 3], int(impacts[o + 5]))
	var deaths: PackedFloat32Array = core.take_deaths()
	for o in range(0, deaths.size(), 4):
		var type := int(deaths[o + 3])
		fx.died(Vector3(deaths[o], deaths[o + 1], deaths[o + 2]), type_colors[type] if type < type_colors.size() else Color.WHITE)
	fx.trail(shot_state, dt)
	fx.trail(stone_state, dt)


## Each burning patch is a low glowing dome that flickers and fades as it burns out.
func _update_fires(delta: float) -> void:
	fire_clock += delta
	var state: PackedFloat32Array = core.fires()
	fx.embers(state, delta * speed)
	var multimesh := fire_layer.multimesh
	var count := mini(state.size() / 5, MAX_FIRES)
	multimesh.visible_instance_count = count
	for n in count:
		var o := n * 5
		var radius: float = state[o + 3]
		var life: float = state[o + 4]
		var flicker := 0.85 + 0.15 * sin(fire_clock * 13.0 + float(n) * 1.7)
		var height := radius * 0.22 * flicker * (0.5 + 0.5 * life)
		multimesh.set_instance_transform(n, Transform3D(Basis().scaled(Vector3(radius, height, radius)), Vector3(state[o], state[o + 1] + 0.2, state[o + 2])))
		multimesh.set_instance_color(n, Color(1.0, 0.45 + 0.15 * flicker, 0.18, 0.42 * minf(life * 3.0, 1.0) * flicker))


## Keeps one visual per started bridge. Planks appear one by one as the crew works.
func _sync_bridges() -> void:
	var state: PackedFloat32Array = core.bridges()
	var seen := {}
	for n in range(0, state.size(), 7):
		var from := Vector3(state[n], state[n + 1], state[n + 2])
		var to := Vector3(state[n + 3], state[n + 4], state[n + 5])
		var key := "%d_%d_%d_%d" % [int(from.x), int(from.z), int(to.x), int(to.z)]
		seen[key] = true
		if not bridge_nodes.has(key):
			bridge_nodes[key] = _make_bridge(from, to)
		_set_bridge_progress(bridge_nodes[key], state[n + 6])
	for key: String in bridge_nodes.keys():
		if not seen.has(key):
			bridge_nodes[key].queue_free()
			bridge_nodes.erase(key)


func _make_bridge(from: Vector3, to: Vector3) -> Node3D:
	var root := Node3D.new()
	root.transform = Transform3D(Basis.looking_at(from - to), from + Vector3(0.0, 0.25, 0.0))
	bridge_root.add_child(root)
	var length := from.distance_to(to)
	var count := maxi(int(length / PLANK_LENGTH), 1)
	var plank := BoxMesh.new()
	plank.size = Vector3(3.8, 0.2, PLANK_LENGTH * 0.92)
	plank.material = Props.solid(Color(0.46, 0.32, 0.2), 0.2, 4.0)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = plank
	multimesh.instance_count = count
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(int(from.x * 10.0) + int(to.z * 10.0))
	for n in count:
		var at := Vector3(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.03, 0.03), (float(n) + 0.5) * PLANK_LENGTH)
		multimesh.set_instance_transform(n, Transform3D(Basis(Vector3.UP, rng.randf_range(-0.03, 0.03)), at))
	var planks := MultiMeshInstance3D.new()
	planks.multimesh = multimesh
	root.add_child(planks)
	root.set_meta("planks", multimesh)
	root.set_meta("length", length)
	root.set_meta("finished", false)
	return root


func _set_bridge_progress(root: Node3D, progress: float) -> void:
	var multimesh: MultiMesh = root.get_meta("planks")
	multimesh.visible_instance_count = int(ceilf(float(multimesh.instance_count) * progress))
	if progress >= 1.0 and not root.get_meta("finished"):
		root.set_meta("finished", true)
		_add_bridge_supports(root)


func _add_bridge_supports(root: Node3D) -> void:
	var length: float = root.get_meta("length")
	var timber := Props.solid(Props.TIMBER, 0.2, 4.0)
	for side: float in [-1.75, 1.75]:
		Props.box(root, Vector3(0.14, 0.14, length), Vector3(side, 1.0, length * 0.5), timber)
		var post_count := int(length / 4.0) + 1
		for n in post_count + 1:
			var z := length * float(n) / float(post_count)
			Props.box(root, Vector3(0.16, 1.1, 0.16), Vector3(side, 0.5, z), timber)
			var world := root.global_transform * Vector3(side, 0.0, z)
			var drop: float = world.y - terrain.height_at(world.x, world.z)
			if drop > 1.0:
				Props.box(root, Vector3(0.3, drop, 0.3), Vector3(side, -drop * 0.5, z), timber)


func _plan_text() -> String:
	if plan.is_empty():
		return ""
	var parts: Array[String] = ["步行 %d 米" % int(plan["walk"])]
	if plan["climb"] > 0.0:
		parts.append("爬坡 %d 米" % int(plan["climb"]))
	if plan["boat"] > 0.0:
		parts.append("划船 %d 米" % int(plan["boat"]))
	if plan["bridges"] > 0:
		parts.append("搭桥 %d 座（%d 米）" % [plan["bridges"], int(plan["span"])])
	if plan["built"] > 0:
		parts.append("走已有的桥 %d 座" % plan["built"])
	return "预计 %d 秒：%s" % [int(plan["time"]), "，".join(parts)]


## Sculpts test terrain directly, reports what the enemies choose, and captures each case.
func run_test(main: Node3D, dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	brush.hide_for_capture()
	main.apply_view("strategy")
	await get_tree().create_timer(4.0).timeout
	var original: PackedFloat32Array = terrain.heights.duplicate()
	var west := -170.0
	var east := 170.0
	var cases: Array[Dictionary] = [
		{"name": "0_open_valley", "lines": []},
		{"name": "1_shallow_trench", "lines": [[Vector2(west, -58.0), Vector2(east, -58.0), 10.0, -2.5]]},
		{"name": "2_deep_trench", "lines": [[Vector2(west, -58.0), Vector2(east, -58.0), 11.0, -16.0]]},
		{"name": "3_wall_with_gap", "lines": [[Vector2(west, -85.0), Vector2(55.0, -85.0), 12.0, 40.0]]},
		{"name": "4_closed_wall", "lines": [[Vector2(west, -85.0), Vector2(east, -85.0), 12.0, 40.0]]},
		{"name": "5_dry_trench", "lines": [[Vector2(west, 60.0), Vector2(east, 60.0), 15.0, -8.0]]},
		# This one runs through the lake, so water floods it and blocks the whole valley.
		{"name": "6_flooded_channel", "lines": [[Vector2(west, -6.0), Vector2(east, -6.0), 15.0, -8.0]]},
	]
	for test: Dictionary in cases:
		_restore_terrain(original)
		for line: Array in test["lines"]:
			_carve(line[0], line[1], line[2], line[3])
		_apply_test_terrain()
		print("ROUTE %s: %s; solve %.1f ms; bridge candidates %d" % [test["name"], _plan_text(), last_solve_ms, core.bridge_candidates()])
		await get_tree().create_timer(1.0).timeout
		await _shot(dir, test["name"])

	# A real wave against the deep trench, sped up, then a second wave over the finished bridge.
	_restore_terrain(original)
	_carve(cases[2]["lines"][0][0], cases[2]["lines"][0][1], cases[2]["lines"][0][2], cases[2]["lines"][0][3])
	_apply_test_terrain()
	await _test_wave(dir, "bridge wave", "7_building_bridge", func() -> bool:
		var state: PackedFloat32Array = core.bridges()
		return state.size() >= 7 and state[6] > 0.5)
	print("ROUTE after bridge wave: bridges standing %d; next plan: %s" % [core.bridges().size() / 7, _plan_text()])
	await get_tree().create_timer(0.5).timeout
	await _shot(dir, "8_bridge_finished")

	var flooded: Array = cases[6]["lines"][0]
	_restore_terrain(original)
	_carve(flooded[0], flooded[1], flooded[2], flooded[3])
	_apply_test_terrain()
	await _test_wave(dir, "boat wave", "9_boats", func() -> bool: return core.boats().count(1.0) >= 150)

	# Cost of a large wave, with frames before and after as a control for outside GPU load.
	_report_frames("no enemies, before", await _measure_frames(240))
	phase = Phase.BATTLE
	route.visible = false
	spawn_wave(300, 0.03)
	var with_enemies: Dictionary = await _measure_frames(600)
	_report_frames("300 enemies", with_enemies)
	await _shot(dir, "10_300_enemies")
	phase = Phase.BUILD
	figures.multimesh.instance_count = 0
	boats.multimesh.instance_count = 0
	_report_frames("no enemies, after", await _measure_frames(240))
	get_tree().quit()


## Runs a real wave at 4x speed, started by the same key a player presses.
func _test_wave(dir: String, label: String, shot_name: String, shot_when: Callable) -> void:
	var predicted: float = plan["time"]
	set_speed(3)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_B
	key.pressed = true
	Input.parse_input_event(key)
	await get_tree().process_frame
	await get_tree().process_frame
	var started := phase == Phase.BATTLE
	var locked_in_battle: bool = brush.locked
	var elapsed := 0.0
	var first := -1.0
	var shot_taken := false
	while phase == Phase.BATTLE:
		await get_tree().process_frame
		elapsed += get_process_delta_time() * speed
		if first < 0.0 and core.arrived() > 0:
			first = elapsed
		if not shot_taken and shot_when.call():
			shot_taken = true
			await _shot(dir, shot_name)
	set_speed(0)
	print("ROUTE %s: started by key %s, terrain locked %s, unlocked after %s; predicted %.0f s, first arrival %.0f s, all done %.0f s; arrived %d of %d" % [
		label, started, locked_in_battle, not brush.locked, predicted, first, elapsed, core.arrived(), WAVE_SIZE,
	])


func _measure_frames(count: int) -> Dictionary:
	var step_total := 0.0
	var step_worst := 0.0
	var frame_total := 0.0
	var previous := Time.get_ticks_usec()
	for n in count:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frame_total += float(now - previous) / 1000.0
		previous = now
		step_total += last_step_ms
		step_worst = maxf(step_worst, last_step_ms)
	return {"fps": 1000.0 * float(count) / frame_total, "step": step_total / float(count), "worst": step_worst}


func _report_frames(label: String, m: Dictionary) -> void:
	print("ROUTE %s: %.0f fps; enemy step avg %.3f ms, worst %.3f ms" % [label, m["fps"], m["step"], m["worst"]])


func _carve(from: Vector2, to: Vector2, half_width: float, change: float) -> void:
	var half: float = terrain.SIZE * 0.5
	var along := to - from
	var length_sq := along.length_squared()
	for j in terrain.RES:
		var z: float = -half + float(j) * terrain.step
		for i in terrain.RES:
			var p := Vector2(-half + float(i) * terrain.step, z)
			var t := clampf((p - from).dot(along) / length_sq, 0.0, 1.0)
			var distance := p.distance_to(from + along * t)
			if distance < half_width:
				var index: int = j * terrain.RES + i
				terrain.heights[index] += change * (1.0 - smoothstep(half_width * 0.7, half_width, distance)) * terrain.edit_mask[index]


func _restore_terrain(saved: PackedFloat32Array) -> void:
	terrain.heights = saved.duplicate()


func _apply_test_terrain() -> void:
	terrain._refresh_rect(0, 0, terrain.RES - 1, terrain.RES - 1)
	terrain.upload_state()
	terrain.water_dirty = true
	brush._refresh_water_if_needed()
	brush._sync_followers(Vector2.ZERO, 0.0, true)
	replan()


func _shot(dir: String, name_text: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name_text])
