extends Node3D
## Sakura valley look test.
## Keys: C next view, right mouse orbit, wheel zoom, WASD pan, P screenshot.
## Brush keys are listed on screen and handled in brush_controller.gd.
## Capture from the command line: -- --shots=dir --list=strategy,pit
## Measure what each rendering feature costs: -- --perf=strategy,pit
## Automated brush test: -- --brushtest=dir
## Automated enemy route test: -- --pathtest=dir
## Automated tower and speed test: -- --towertest=dir
## Automated interface test: -- --uitest=dir, or --uilayout=dir for only the layout checks
## Choose a level, named after a file in data/levels: -- --level=sandbox
## Automated first-level test: -- --leveltest=dir
## Play out the strategies against the level's numbers, with no waiting: -- --balance=name
## How far off the middle of the west road a ridge can be dropped and still close it: -- --ridgesweep

const TerrainData = preload("res://scripts/terrain_data.gd")
const Flora = preload("res://scripts/flora.gd")
const Props = preload("res://scripts/props.gd")
const BrushController = preload("res://scripts/brush_controller.gd")
const BuildHistory = preload("res://scripts/build_history.gd")
const PathManager = preload("res://scripts/path_manager.gd")
const TowerManager = preload("res://scripts/tower_manager.gd")
const GameUI = preload("res://scripts/game_ui.gd")
const GameConfig = preload("res://scripts/game_config.gd")
const TerrainTools = preload("res://scripts/terrain_tools.gd")
const TerrainFeel = preload("res://scripts/terrain_feel.gd")

const DEFAULT_LEVEL := "level_01"
const MAX_DIST := 720.0
const SHADOW_REACH := 460.0

## Same direction as SUN_DIR in sun_light.gdshaderinc.
const SUN_DIR := Vector3(-0.5498, 0.6198, -0.5598)
const HAZE_COLOR := Color(0.46, 0.62, 0.68)
const VIEWS := {
	"strategy": {"target": Vector3(4.0, 6.0, 8.0), "yaw": 0.12, "pitch": -36.0, "dist": 262.0, "fov": 38.0, "far": 400.0, "near": 0.0, "amount": 0.04},
	"overview": {"target": Vector3(0.0, 24.0, -20.0), "yaw": -0.25, "pitch": -15.0, "dist": 205.0, "fov": 48.0, "far": 420.0, "near": 0.0, "amount": 0.04},
	"pit": {"target": Vector3(-6.0, 3.0, -38.0), "yaw": 0.5, "pitch": -33.0, "dist": 78.0, "fov": 34.0, "far": 108.0, "near": 40.0, "amount": 0.07},
	"lake": {"target": Vector3(46.0, 3.0, -8.0), "yaw": -0.2, "pitch": -24.0, "dist": 58.0, "fov": 40.0, "far": 90.0, "near": 0.0, "amount": 0.05},
	"village": {"target": Vector3(16.0, 6.0, 114.0), "yaw": 0.25, "pitch": -24.0, "dist": 44.0, "fov": 40.0, "far": 62.0, "near": 14.0, "amount": 0.06},
	"grove": {"target": Vector3(-8.0, 10.0, 30.0), "yaw": 0.3, "pitch": -9.0, "dist": 58.0, "fov": 38.0, "far": 95.0, "near": 0.0, "amount": 0.04},
	"low": {"target": Vector3(16.0, 12.0, 112.0), "yaw": 0.1, "pitch": -3.0, "dist": 42.0, "fov": 42.0, "far": 66.0, "near": 7.0, "amount": 0.05},
}
const VIEW_ORDER: Array[String] = ["strategy", "overview", "pit", "lake", "village", "low", "grove"]

var terrain
## Every tree on the map, so tests can hide them.
var tree_nodes: Array[Node3D] = []
var camera: Camera3D
var sun: DirectionalLight3D
var environment: Environment
var meadow_map: ImageTexture
var water_node: MeshInstance3D
var water_material: ShaderMaterial
var live_ground_material: ShaderMaterial
var shafts: MeshInstance3D
var brush: Node
var history: BuildHistory
var paths: Node
var towers: Node
var tools: Node
var feel: Node
var ui: CanvasLayer
var level_id := DEFAULT_LEVEL
var views := {}
var view_order: Array[String] = []
## How far the camera trembles right now, in metres.
var camera_tremor := 0.0
var attributes: CameraAttributesPractical
var target := Vector3.ZERO
var yaw := 0.0
var pitch := -40.0
var dist := 200.0
var view_index := 0


func _ready() -> void:
	var start := Time.get_ticks_msec()
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		args[parts[0]] = parts[1] if parts.size() > 1 else ""
	level_id = args.get("level", GameConfig.chosen_level if GameConfig.chosen_level != "" else DEFAULT_LEVEL)
	var level: Dictionary = GameConfig.level(level_id)
	var tools_config: Dictionary = GameConfig.tools()
	views = _read_views(level)
	view_order.assign(VIEW_ORDER)
	if level.has("view_order"):
		view_order = []
		view_order.assign(level["view_order"])
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261104
	terrain = TerrainData.new()
	terrain.setup(level["map"])
	terrain.build()
	print("BUILD terrain data ", Time.get_ticks_msec() - start, " ms")
	meadow_map = terrain.build_meadow_map()
	_build_environment()
	_build_ground()
	_build_water()
	_build_clouds(level["map"])
	tree_nodes = []
	var trees: Array[Vector3] = Flora.build_trees(self, terrain, rng, tree_nodes)
	print("BUILD trees ", trees.size(), " at ", Time.get_ticks_msec() - start, " ms")
	var petal_map: PackedFloat32Array = Flora.make_petal_map(terrain, trees)
	var grass_count: int = Flora.build_grass(self, terrain, rng, petal_map, meadow_map)
	print("BUILD grass tufts ", grass_count, " at ", Time.get_ticks_msec() - start, " ms")
	Flora.build_ground_petals(self, terrain, rng, petal_map)
	Flora.build_water_petals(self, terrain, rng)
	Flora.build_falling_petals(self)
	var village: Dictionary = Props.build_village(self, terrain, rng)
	_build_camera()
	_build_shafts()
	var lanterns: Array[Node3D] = village["lanterns"]
	feel = TerrainFeel.new()
	add_child(feel)
	feel.setup(self, tools_config["feel"])
	history = BuildHistory.new()
	history.limit = int(tools_config["brush"]["max_undo"])
	brush = BrushController.new()
	brush.history = history
	add_child(brush)
	brush.setup(terrain, camera, water_node, tree_nodes, lanterns, tools_config, float(level["start_gold"]), feel)
	paths = PathManager.new()
	add_child(paths)
	paths.setup(terrain, brush, level, GameConfig.enemies(), tools_config["routing"])
	# Added after the brush, so it sees mouse clicks first and can claim clicks on towers.
	towers = TowerManager.new()
	add_child(towers)
	var overlay_materials: Array[ShaderMaterial] = [live_ground_material, Flora.grass_material, water_material]
	towers.setup(terrain, camera, brush, paths, overlay_materials, GameConfig.towers())
	# Added after the towers for the same reason: it gets first look at clicks while placing.
	tools = TerrainTools.new()
	add_child(tools)
	tools.setup(terrain, camera, brush, paths, towers, feel, tools_config)
	ui = GameUI.new()
	add_child(ui)
	ui.setup(self, brush, paths, towers, tools)
	# Exit before the controllers so they can release objects kept for undo.
	add_child(history)
	apply_view(view_order[0])
	print("BUILD ", level_id, " total ", Time.get_ticks_msec() - start, " ms; GPU: ", RenderingServer.get_video_adapter_name())
	if args.has("ridgesweep"):
		var sweep: Node = load("res://scripts/ridge_sweep_test.gd").new()
		add_child(sweep)
		sweep.run(self)
	elif args.has("balance"):
		var balance: Node = load("res://scripts/balance_test.gd").new()
		add_child(balance)
		balance.run(self, args["balance"])
	elif args.has("leveltest"):
		var level_test: Node = load("res://scripts/level_test.gd").new()
		add_child(level_test)
		level_test.run(self, args["leveltest"], args.has("lose"))
	elif args.has("uitest") or args.has("uilayout"):
		var ui_test: Node = load("res://scripts/ui_test.gd").new()
		add_child(ui_test)
		ui_test.run(self, args.get("uitest", args.get("uilayout", "")), args.has("uitest"))
	elif args.has("towertest"):
		var test: Node = load("res://scripts/tower_test.gd").new()
		add_child(test)
		test.run(self, args["towertest"])
	elif args.has("fxdemo"):
		var fx_demo: Node = load("res://scripts/fx_test.gd").new()
		add_child(fx_demo)
		fx_demo.demo(self, args["fxdemo"], args)
	elif args.has("fxtest"):
		var fx_test: Node = load("res://scripts/fx_test.gd").new()
		add_child(fx_test)
		fx_test.run(self, args["fxtest"], args)
	elif args.has("levelcheck"):
		var check: Node = load("res://scripts/level_check.gd").new()
		add_child(check)
		if args.has("play"):
			check.play(self)
		elif args.has("dam"):
			check.dam(self, args["dam"])
		elif args.has("uishot"):
			check.ui_shot(self, args["uishot"])
		else:
			check.run(self, args["levelcheck"])
	elif args.has("pathtest"):
		paths.run_test(self, args["pathtest"])
	elif args.has("brushtest"):
		brush.run_test(self, args["brushtest"])
	elif args.has("perf"):
		_perf(String(args["perf"]).split(","))
	elif args.has("shots"):
		_capture(args["shots"], String(args.get("list", "strategy")).split(","))


## A level can name its own camera spots. Otherwise the sandbox spots apply.
func _read_views(level: Dictionary) -> Dictionary:
	if not level.has("views"):
		return VIEWS
	var result := {}
	for view_name: String in level["views"]:
		var view: Dictionary = level["views"][view_name].duplicate()
		view["target"] = GameConfig.vector3(view["target"])
		result[view_name] = view
	return result


func _build_environment() -> void:
	var sky_material := ShaderMaterial.new()
	sky_material.shader = load("res://shaders/sky.gdshader")
	sky_material.set_shader_parameter("top_color", Color(0.2, 0.42, 0.62))
	sky_material.set_shader_parameter("horizon_color", Color(0.52, 0.68, 0.74))
	sky_material.set_shader_parameter("ground_color", Color(0.3, 0.38, 0.36))
	sky_material.set_shader_parameter("cloud_light", Color(0.9, 0.9, 0.86))
	sky_material.set_shader_parameter("cloud_shadow", Color(0.5, 0.6, 0.68))
	sky_material.set_shader_parameter("cloud_amount", 0.5)
	sky_material.set_shader_parameter("sun_color", Color(1.0, 0.88, 0.68))
	sky_material.set_shader_parameter("sun_glow", 0.14)
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 1.0
	environment.ambient_light_energy = 0.42
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_white = 5.0
	environment.tonemap_exposure = 0.92
	environment.ssao_enabled = true
	environment.ssao_radius = 2.4
	environment.ssao_intensity = 2.6
	environment.ssao_power = 1.7
	environment.ssao_light_affect = 0.3
	environment.ssil_enabled = true
	environment.ssil_radius = 7.0
	environment.ssil_intensity = 1.0
	environment.glow_enabled = true
	environment.glow_intensity = 0.3
	environment.glow_strength = 1.0
	environment.glow_bloom = 0.0
	environment.glow_hdr_threshold = 1.3
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	environment.fog_density = 0.00025
	environment.fog_light_color = HAZE_COLOR
	environment.fog_sky_affect = 0.0
	environment.fog_aerial_perspective = 0.2
	environment.adjustment_enabled = true
	environment.adjustment_contrast = 1.06
	environment.adjustment_saturation = 1.12
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)

	sun = DirectionalLight3D.new()
	sun.basis = Basis.looking_at(-SUN_DIR)
	sun.light_color = Color(1.0, 0.86, 0.66)
	sun.light_energy = 2.5
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 460.0
	sun.directional_shadow_split_1 = 0.3
	sun.directional_shadow_blend_splits = true
	sun.light_angular_distance = 1.6
	sun.shadow_blur = 1.4
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 1.4
	add_child(sun)


func _build_ground() -> void:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/terrain.gdshader")
	material.set_shader_parameter("meadow_map", meadow_map)
	material.set_shader_parameter("meadow_size", terrain.SIZE)
	material.set_shader_parameter("water_level", terrain.WATER_LEVEL)
	material.set_shader_parameter("dig_scale", terrain.DIG_SCALE)
	material.set_shader_parameter("haze_color", HAZE_COLOR)
	var outer := MeshInstance3D.new()
	outer.mesh = terrain.build_outer_mesh()
	outer.material_override = material
	add_child(outer)
	# The playable terrain takes its shape from the live texture, so a brush only updates that.
	var live_material: ShaderMaterial = material.duplicate()
	live_ground_material = live_material
	live_material.set_shader_parameter("live_terrain", true)
	terrain.bind_state(live_material)
	var ground := MeshInstance3D.new()
	ground.mesh = terrain.build_mesh()
	ground.material_override = live_material
	var half: float = terrain.SIZE * 0.5
	ground.custom_aabb = AABB(Vector3(-half, -60.0, -half), Vector3(terrain.SIZE, 260.0, terrain.SIZE))
	add_child(ground)


func _build_water() -> void:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/water.gdshader")
	water_material = material
	var water := MeshInstance3D.new()
	water_node = water
	water.mesh = terrain.build_water_mesh()
	water.material_override = material
	water.layers = Flora.LAYER_MAIN_ONLY
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	water.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(water)


## Floating levels hang over a sea of clouds, which hides the floor of the void.
func _build_clouds(map: Dictionary) -> void:
	if not map.has("cloud_height"):
		return
	var plane := PlaneMesh.new()
	plane.size = Vector2(3200.0, 3200.0)
	plane.subdivide_width = 159
	plane.subdivide_depth = 159
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/cloud_sea.gdshader")
	var noise := FastNoiseLite.new()
	noise.seed = 91
	noise.frequency = 0.012
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.55
	var billows := NoiseTexture2D.new()
	billows.width = 512
	billows.height = 512
	billows.seamless = true
	billows.generate_mipmaps = true
	billows.noise = noise
	var normals := NoiseTexture2D.new()
	normals.width = 512
	normals.height = 512
	normals.seamless = true
	normals.as_normal_map = true
	normals.bump_strength = 6.0
	normals.generate_mipmaps = true
	normals.noise = noise
	material.set_shader_parameter("billow_map", billows)
	material.set_shader_parameter("billow_normals", normals)
	var clouds := MeshInstance3D.new()
	clouds.mesh = plane
	clouds.material_override = material
	clouds.position.y = float(map["cloud_height"])
	clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	clouds.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(clouds)


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.far = 3600.0
	camera.near = 0.5
	attributes = CameraAttributesPractical.new()
	attributes.dof_blur_far_enabled = true
	attributes.dof_blur_near_enabled = true
	camera.attributes = attributes
	add_child(camera)
	camera.make_current()


## Sun shafts and edge darkening, drawn as one full-screen pass after the scene.
func _build_shafts() -> void:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/light_shafts.gdshader")
	material.render_priority = 100
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	quad.subdivide_width = 95
	quad.subdivide_depth = 53
	quad.material = material
	shafts = MeshInstance3D.new()
	shafts.mesh = quad
	shafts.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shafts.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	shafts.custom_aabb = AABB(Vector3(-100000.0, -100000.0, -100000.0), Vector3(200000.0, 200000.0, 200000.0))
	add_child(shafts)


func apply_view(view: String) -> void:
	if not views.has(view):
		view = view_order[0]
	var v: Dictionary = views[view]
	target = v["target"]
	yaw = v["yaw"]
	pitch = v["pitch"]
	dist = v["dist"]
	camera.fov = v["fov"]
	# Depth blur only matters up close, so the wide game views skip its cost.
	camera.attributes = attributes if dist < 120.0 else null
	attributes.dof_blur_far_distance = v["far"]
	attributes.dof_blur_far_transition = v["far"] * 0.45
	attributes.dof_blur_near_enabled = float(v["near"]) > 0.0
	attributes.dof_blur_near_distance = v["near"]
	attributes.dof_blur_near_transition = float(v["near"]) * 0.45
	attributes.dof_blur_amount = v["amount"]
	_update_camera()


func _update_camera() -> void:
	var rot := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, deg_to_rad(pitch))
	var tremor := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * camera_tremor
	camera.global_transform = Transform3D(rot, target + rot.z * dist + tremor)
	# Shadows have to reach past the far edge of the map, however far the camera has pulled back.
	var shadow_reach := maxf(SHADOW_REACH, dist + 300.0)
	if not is_equal_approx(sun.directional_shadow_max_distance, shadow_reach):
		sun.directional_shadow_max_distance = shadow_reach
		sun.directional_shadow_split_1 = clampf(maxf(138.0, dist * 0.95) / shadow_reach, 0.1, 0.8)


func _process(delta: float) -> void:
	var move := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		move.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		move.z += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		move.x += 1.0
	if move != Vector3.ZERO:
		target += Basis(Vector3.UP, yaw) * move.normalized() * dist * 0.6 * delta
	_update_camera()


## Here rather than in _unhandled_input, so the view keeps turning when the mouse crosses a panel.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		yaw -= event.relative.x * 0.005
		pitch = clampf(pitch - event.relative.y * 0.15, -85.0, -1.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = maxf(dist * 0.9, 8.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = minf(dist * 1.1, MAX_DIST)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_C:
				view_index = (view_index + 1) % view_order.size()
				apply_view(view_order[view_index])
			KEY_P:
				_save_screenshot("user://shot_%d.png" % Time.get_ticks_msec())


func _save_screenshot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("SAVED ", ProjectSettings.globalize_path(path))


## Times a run of frames. Returns average, 99th percentile and worst frame times in milliseconds.
func _measure(frame_count: int) -> Dictionary:
	var rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var times := PackedFloat32Array()
	times.resize(frame_count)
	var gpu := 0.0
	var cpu := 0.0
	var previous := Time.get_ticks_usec()
	for n in frame_count:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		times[n] = float(now - previous) / 1000.0
		previous = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
	var total := 0.0
	for t in times:
		total += t
	times.sort()
	return {
		"avg": total / float(frame_count),
		"p99": times[int(float(frame_count) * 0.99)],
		"worst": times[frame_count - 1],
		"gpu": gpu / float(frame_count),
		"cpu": cpu / float(frame_count),
		"triangles": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"draws": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
	}


func _report(label: String, m: Dictionary) -> void:
	print("PERF %s: %.0f fps, avg %.1f ms, p99 %.1f, worst %.1f; gpu %.1f, cpu %.1f; %.1fM triangles, %d draws" % [
		label, 1000.0 / float(m["avg"]), m["avg"], m["p99"], m["worst"], m["gpu"], m["cpu"], float(m["triangles"]) / 1000000.0, m["draws"],
	])


## Switches off one feature at a time, to show what each one really costs.
func _perf(views: PackedStringArray) -> void:
	brush.hide_for_capture()
	ui.visible = false
	await get_tree().create_timer(4.0).timeout
	var viewport := get_viewport()
	var tests: Array[Array] = [
		["all on", func() -> void: pass, func() -> void: pass],
		["no ssil", func() -> void: environment.ssil_enabled = false, func() -> void: environment.ssil_enabled = true],
		["no ssao", func() -> void: environment.ssao_enabled = false, func() -> void: environment.ssao_enabled = true],
			["no glow", func() -> void: environment.glow_enabled = false, func() -> void: environment.glow_enabled = true],
		["no msaa", func() -> void: viewport.msaa_3d = Viewport.MSAA_DISABLED, func() -> void: viewport.msaa_3d = Viewport.MSAA_2X],
		["no shafts", func() -> void: shafts.visible = false, func() -> void: shafts.visible = true],
			["no grass", func() -> void: get_tree().call_group("grass", "hide"), func() -> void: get_tree().call_group("grass", "show")],
	]
	for view in views:
		apply_view(view)
		await get_tree().create_timer(3.0).timeout
		for test: Array in tests:
			test[1].call()
			await get_tree().create_timer(1.5).timeout
			_report("%s | %s" % [view, test[0]], await _measure(120))
			test[2].call()
	get_tree().quit()


func _capture(dir: String, items: PackedStringArray) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	brush.hide_for_capture()
	ui.visible = false
	await get_tree().create_timer(4.0).timeout
	for view in items:
		apply_view(view)
		await get_tree().create_timer(4.0).timeout
		_report(view, await _measure(240))
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, view])
	get_tree().quit()
