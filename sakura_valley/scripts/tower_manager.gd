extends Node
## Tower placement, aiming, range display and removal. Firing happens in native/path_core.cpp.
## A tower stands square to whatever slope it is built on, and its gun can point anywhere.
## New tower types only need another entry in data/towers.json, plus their own range shape later on.

const Props = preload("res://scripts/props.gd")
const TowerModels = preload("res://scripts/tower_models.gd")
const Flora = preload("res://scripts/flora.gd")

## Sent when a different tower is selected, or none.
signal selection_changed
## Sent when the selected tower's aim or surroundings change.
signal aim_changed
## Sent after the selected tower takes an upgrade, with the name of what it became.
signal upgraded(tower: Dictionary, title: String)

enum Mode { IDLE, PLACING, AIMING }
enum { HINT_INFO, HINT_OK, HINT_WARN, HINT_BAD }

const GHOST_OK := Color(0.62, 0.82, 0.55, 0.6)
const GHOST_WARN := Color(0.93, 0.76, 0.42, 0.6)
const GHOST_BAD := Color(0.88, 0.48, 0.42, 0.6)

const FOOTPRINT := 3.5
const PAD_INNER := 4.4
const PAD_OUTER := 7.5
const PLINTH_HEIGHT := 0.7
const PLINTH_DEPTH := 2.0
const PIVOT_HEIGHT := 10.6
const TOWER_HEIGHT := 12.0
const TURN_STEP := PI / 12.0
const NUDGE := 0.0873 # 5 degrees
const AIM_START_PIXELS := 24.0

## Numbers from data/towers.json, one spec per tower type in the order written there.
## half_angle (radians) and type (the key) are added here. normal_spec is the plain cannon.
var specs := {}
var normal_spec := {}
## The type a new tower will be, while placing.
var place_type := "normal"
var spacing := 9.0
var top_spacing := 7.0
var max_tilt := 88.0
## Bumps smaller than this need no extra stonework. Larger ones cost more, up to max_roughness.
var smooth_roughness := 0.3
var max_roughness := 3.5
var foundation_extra := 500
var refund_rate := 0.7
## Star upgrades after the last branch: their prices, and the damage each one adds.
var star_costs: Array = []
var star_bonus := 0.15

var terrain
var camera: Camera3D
var brush: Node
var paths: Node
var core
var rock: Mesh
var rng := RandomNumberGenerator.new()
var overlay_materials: Array[ShaderMaterial] = []
var range_image: Image
var range_texture: ImageTexture
var map_res := 0

var towers: Array[Dictionary] = []
var pending_removals: Array[Dictionary] = []
var mode := Mode.IDLE
var selected := {}
## Towers playing their firing motion.
var kicking: Array[Dictionary] = []
var place_yaw := 0.0
var place_pitch := 0.0
var auto_aim := true
var place_check := {}
var last_key := PackedFloat32Array()
var aim_lift := 0.0
var aim_saved_yaw := 0.0
var aim_saved_pitch := 0.0
var aim_anchor := Vector2.ZERO
var aim_following := false
var slider_tower := {}
var slider_start := Vector2.ZERO
var slider_interrupted := false

var cone_view: MeshInstance3D
var range_shown := false
var cone_meshes := {}
var ghost: Node3D
var ghost_barrel: MeshInstance3D
var ghost_material: StandardMaterial3D
## What the interface should tell the player right now. Empty means nothing to say.
var hint_text := ""
var hint_sub := ""
var hint_kind := HINT_INFO


func setup(data, view_camera: Camera3D, brush_node: Node, path_node: Node, materials: Array[ShaderMaterial], tower_config: Dictionary) -> void:
	for key: String in tower_config:
		if key == "stars" or key == "rules":
			continue
		var spec: Dictionary = tower_config[key].duplicate()
		spec["type"] = key
		spec["half_angle"] = deg_to_rad(float(spec["cone_degrees"]) * 0.5)
		specs[key] = spec
	normal_spec = specs["normal"]
	var rules: Dictionary = tower_config["rules"]
	spacing = rules["spacing"]
	top_spacing = rules["top_spacing"]
	max_tilt = rules["max_tilt_degrees"]
	smooth_roughness = rules["smooth_roughness"]
	max_roughness = rules["max_roughness"]
	foundation_extra = rules["foundation_extra_cost"]
	refund_rate = rules["refund"]
	var stars: Dictionary = tower_config.get("stars", {})
	star_costs = stars.get("costs", [])
	star_bonus = stars.get("damage_bonus", 0.0)
	terrain = data
	camera = view_camera
	brush = brush_node
	paths = path_node
	core = paths.core
	paths.tower_fired.connect(_on_tower_fired)
	overlay_materials = materials
	rock = Props.make_rock_mesh(11)
	rng.seed = 4242
	# The route grid in native/path_core.cpp uses every second terrain point.
	map_res = (terrain.RES - 1) / 2 + 1
	range_image = Image.create_empty(map_res, map_res, false, Image.FORMAT_L8)
	range_texture = ImageTexture.create_from_image(range_image)
	for material in overlay_materials:
		material.set_shader_parameter("range_map", range_texture)
		material.set_shader_parameter("range_size_res", Vector2(terrain.SIZE, float(map_res)))
	_build_cone_view()
	_build_ghost()
	brush.terrain_changed.connect(_on_terrain_changed)
	brush.tool_selected.connect(_on_tool_selected)
	brush.history.before_undo.connect(cancel_pending_aim)
	brush.history.before_commit.connect(commit_pending_aim)
	paths.battle_ended.connect(_on_battle_ended)


## The cone in the air, along +Z with its apex at the origin. Its mesh changes with the tower shown.
func _build_cone_view() -> void:
	cone_view = MeshInstance3D.new()
	cone_view.mesh = _cone_mesh(normal_spec["half_angle"], normal_spec["range"])
	cone_view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cone_view.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	cone_view.visible = false
	add_child(cone_view)


## Cone meshes by angle and reach, so upgraded towers show their own shape without rebuilding each frame.
## A tower that cannot hit close up gets a cone with its tip cut off at near metres.
func _cone_mesh(half: float, reach: float, near := 0.0) -> Mesh:
	var key := "%.3f_%d_%d" % [half, int(round(reach)), int(round(near))]
	if cone_meshes.has(key):
		return cone_meshes[key]
	var sides := 64
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var indices := PackedInt32Array()
	var rim_points := PackedVector3Array()
	var near_points := PackedVector3Array()
	for s in sides + 1:
		var a := TAU * float(s) / float(sides)
		var ring_dir := Vector3(cos(a), sin(a), 0.0)
		var skin_normal := ring_dir * cos(half) - Vector3.BACK * sin(half)
		var inner := (ring_dir * sin(half) + Vector3.BACK * cos(half)) * near
		near_points.append(inner)
		verts.append(inner)
		norms.append(skin_normal)
		var rim := ring_dir * sin(half) * reach + Vector3.BACK * cos(half) * reach
		verts.append(rim)
		norms.append(skin_normal)
		rim_points.append(rim)
	for s in sides:
		var o := s * 2
		# Two triangles per side. With no cut-off tip the second one has no area.
		indices.append_array(PackedInt32Array([o, o + 1, o + 3, o, o + 3, o + 2]))
	# The round far end of the cone, which is part of a sphere around the apex.
	var cap_rings := 6
	var cap_first := verts.size()
	for r in cap_rings + 1:
		var theta := half * float(r) / float(cap_rings)
		for s in sides + 1:
			var a := TAU * float(s) / float(sides)
			var direction := Vector3(cos(a) * sin(theta), sin(a) * sin(theta), cos(theta))
			verts.append(direction * reach)
			norms.append(direction)
	for r in cap_rings:
		for s in sides:
			var o := cap_first + r * (sides + 1) + s
			var below := o + sides + 1
			indices.append_array(PackedInt32Array([o, below, o + 1, o + 1, below, below + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var skin := ShaderMaterial.new()
	skin.shader = load("res://shaders/cone_volume.gdshader")
	mesh.surface_set_material(0, skin)
	# Outline: the rim, four edges from the apex, and the line the gun points along.
	var lines := PackedVector3Array()
	for s in sides:
		lines.append_array(PackedVector3Array([rim_points[s], rim_points[s + 1]]))
	for s in range(0, sides, sides / 4):
		lines.append_array(PackedVector3Array([near_points[s], rim_points[s]]))
	if near > 0.0:
		for s in sides:
			lines.append_array(PackedVector3Array([near_points[s], near_points[s + 1]]))
	lines.append_array(PackedVector3Array([Vector3.BACK * near, Vector3.BACK * reach]))
	var line_arrays := []
	line_arrays.resize(Mesh.ARRAY_MAX)
	line_arrays[Mesh.ARRAY_VERTEX] = lines
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, line_arrays)
	var line_material := StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	line_material.albedo_color = Color(1.0, 0.9, 0.5, 0.75)
	mesh.surface_set_material(1, line_material)
	cone_meshes[key] = mesh
	return mesh


func _build_ghost() -> void:
	ghost_material = StandardMaterial3D.new()
	ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_material.no_depth_test = true
	ghost = Node3D.new()
	ghost.visible = false
	add_child(ghost)
	var body := CylinderMesh.new()
	body.top_radius = 2.6
	body.bottom_radius = 3.1
	body.height = PIVOT_HEIGHT - 1.5
	body.material = ghost_material
	_add_ghost_part(body, Vector3.UP * (PLINTH_HEIGHT + (PIVOT_HEIGHT - 1.5) * 0.5))
	var plate := CylinderMesh.new()
	plate.top_radius = 4.0
	plate.bottom_radius = 4.4
	plate.height = PLINTH_HEIGHT
	plate.material = ghost_material
	_add_ghost_part(plate, Vector3.UP * PLINTH_HEIGHT * 0.5)
	var barrel := BoxMesh.new()
	barrel.size = Vector3(1.0, 1.0, 8.0)
	barrel.material = ghost_material
	ghost_barrel = MeshInstance3D.new()
	ghost_barrel.mesh = barrel
	ghost_barrel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ghost.add_child(ghost_barrel)


func _add_ghost_part(mesh: Mesh, at: Vector3) -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ghost.add_child(node)


## Starts placing a tower of this type, or stops if that type was already being placed.
func toggle_placing(type := "normal") -> void:
	if mode == Mode.PLACING and place_type == type:
		_set_mode(Mode.IDLE)
		return
	place_type = type
	_set_mode(Mode.PLACING)


## The spec of the tower being placed.
func place_spec() -> Dictionary:
	return specs[place_type]


## How tall a tower's gun stands above its base, which sets how high it shoots from.
func _pivot(spec: Dictionary) -> float:
	return float(spec.get("pivot_height", PIVOT_HEIGHT))


## A catapult throws in every direction, so there is nothing to aim.
static func aimable(spec: Dictionary) -> bool:
	return not spec.get("lob", false)


func _set_mode(value: Mode) -> void:
	if mode == Mode.AIMING and value != Mode.AIMING and not selected.is_empty():
		_record_aim(selected, Vector2(aim_saved_yaw, aim_saved_pitch))
	mode = value
	brush.paused = mode != Mode.IDLE
	ghost.visible = false
	if mode == Mode.IDLE:
		_set_hint(HINT_INFO, "")
	auto_aim = true
	aim_lift = 0.0
	last_key = PackedFloat32Array()
	if mode == Mode.PLACING:
		deselect()
	elif mode == Mode.IDLE and selected.is_empty():
		_hide_range()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		_handle_key(event)
		return
	if not event is InputEventMouseButton or not event.pressed:
		return
	var wheel: float = 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else (-1.0 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else 0.0)
	match mode:
		Mode.PLACING:
			if wheel != 0.0:
				auto_aim = false
				if event.shift_pressed:
					place_pitch = clampf(place_pitch + wheel * NUDGE, -PI * 0.5, PI * 0.5)
				else:
					place_yaw += wheel * TURN_STEP
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				if brush.has_hit:
					place_at(brush.hit.x, brush.hit.z, place_yaw, place_pitch)
				get_viewport().set_input_as_handled()
		Mode.AIMING:
			if wheel != 0.0:
				aim_lift = clampf(aim_lift + wheel * NUDGE, -PI, PI)
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				_set_mode(Mode.IDLE)
				get_viewport().set_input_as_handled()
		Mode.IDLE:
			if event.button_index == MOUSE_BUTTON_LEFT:
				var tower := _tower_under_mouse()
				if not tower.is_empty():
					select(tower)
					get_viewport().set_input_as_handled()
				elif not selected.is_empty():
					# This click only closes the panel, so it must not also dig into the ground.
					deselect()
					get_viewport().set_input_as_handled()


func _handle_key(event: InputEventKey) -> void:
	# Each tower type has its own key in data/towers.json.
	for type: String in specs:
		if event.physical_keycode == OS.find_keycode_from_string(String(specs[type].get("key", ""))):
			if not event.echo:
				toggle_placing(type)
			get_viewport().set_input_as_handled()
			return
	var handled := true
	match event.physical_keycode:
		KEY_V:
			if not event.echo and not selected.is_empty() and aimable(selected["spec"]):
				start_aiming()
		KEY_ESCAPE:
			if event.echo:
				return
			if mode == Mode.AIMING:
				_set_tower_aim(selected, aim_saved_yaw, aim_saved_pitch)
				_set_mode(Mode.IDLE)
			elif mode == Mode.PLACING:
				_set_mode(Mode.IDLE)
			else:
				deselect()
		KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN:
			if selected.is_empty() or not aimable(selected["spec"]):
				return
			var before := Vector2(selected["yaw"], selected["pitch"])
			var yaw: float = selected["yaw"]
			var pitch: float = selected["pitch"]
			if event.physical_keycode == KEY_LEFT:
				yaw += NUDGE
			elif event.physical_keycode == KEY_RIGHT:
				yaw -= NUDGE
			elif event.physical_keycode == KEY_UP:
				pitch += NUDGE
			else:
				pitch -= NUDGE
			_set_tower_aim(selected, yaw, clampf(pitch, -PI * 0.5, PI * 0.5))
			if mode != Mode.AIMING and slider_tower.is_empty():
				_record_aim(selected, before)
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _tower_under_mouse() -> Dictionary:
	var mouse: Vector2 = brush.current_mouse()
	var origin := camera.project_ray_origin(mouse)
	var finish := origin + camera.project_ray_normal(mouse) * 900.0
	var best := {}
	var best_distance := 5.0
	for tower in towers:
		var base: Vector3 = tower["center"]
		var top: Vector3 = base + Vector3(tower["normal"]) * (_pivot(tower["spec"]) + 1.4)
		var points := Geometry3D.get_closest_points_between_segments(origin, finish, base, top)
		var distance := points[0].distance_to(points[1])
		if distance < best_distance:
			best_distance = distance
			best = tower
	return best


static func aim_vector(yaw: float, pitch: float) -> Vector3:
	return Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))


static func _up_basis(up: Vector3, forward: Vector3) -> Basis:
	var flat := forward - up * forward.dot(up)
	if flat.length() < 0.01:
		flat = up.cross(Vector3.RIGHT)
		if flat.length() < 0.01:
			flat = up.cross(Vector3.BACK)
	var z := flat.normalized()
	return Basis(up.cross(z).normalized(), up, z)


## Checks a spot against the building rules. Slope alone never rules a spot out unless it is
## almost a sheer wall: what matters is that the ground is roughly flat across the footing.
func check_spot(x: float, z: float, type := "") -> Dictionary:
	var spec: Dictionary = specs[type if type != "" else place_type]
	var half: float = terrain.SIZE * 0.5
	if absf(x) > half - 8.0 or absf(z) > half - 8.0:
		return {"ok": false, "reason": "这里不能建造"}
	var plane: Dictionary = terrain.fit_ground_plane(x, z, FOOTPRINT)
	var samples: PackedVector3Array = plane["samples"]
	for s in samples:
		var index: int = terrain._index_of(x + s.x, z + s.z)
		# Water mask rather than height: a dry pit can lie below the water level.
		if terrain.water_mask[index] != 0:
			return {"ok": false, "reason": "这里有水，不能建造"}
		if terrain.heights[index] < terrain.void_level + 1.0:
			return {"ok": false, "reason": "这里是云海，不能建造"}
		if terrain.base_edit_mask[index] <= 0.0:
			var why: String = terrain.no_build_reason(x + s.x, z + s.z)
			return {"ok": false, "reason": why if why != "" else "这里不能建造"}
	var normal: Vector3 = plane["normal"]
	var center: Vector3 = plane["center"]
	var base: Vector3 = center + normal * PLINTH_HEIGHT
	var apex: Vector3 = base + normal * _pivot(spec)
	var tilt := rad_to_deg(acos(clampf(normal.y, -1.0, 1.0)))
	var roughness: float = plane["roughness"]
	if tilt > max_tilt:
		return {"ok": false, "reason": "这里几乎是垂直的峭壁（%d°），上限 %d°" % [int(tilt), int(max_tilt)], "tilt": tilt, "roughness": roughness}
	if roughness > max_roughness:
		return {"ok": false, "reason": "地面太崎岖：起伏 %.1f 米，上限 %.1f 米" % [roughness, max_roughness], "tilt": tilt, "roughness": roughness}
	for tower in towers:
		if center.distance_to(tower["center"]) < spacing or apex.distance_to(tower["apex"]) < top_spacing:
			return {"ok": false, "reason": "离其他塔太近"}
	# A tower leaning across a gully would run straight into the far side.
	for along: float in [4.0, 8.0, _pivot(spec) + 1.4]:
		var point := base + normal * along
		if point.y < terrain.height_at(point.x, point.z) - 0.5:
			return {"ok": false, "reason": "塔身会撞到山体", "tilt": tilt, "roughness": roughness}
	var extra := clampf((roughness - smooth_roughness) / (max_roughness - smooth_roughness), 0.0, 1.0)
	return {
		"ok": true, "plane": plane, "normal": normal, "center": center, "base": base, "apex": apex,
		"tilt": tilt, "roughness": roughness, "rough": extra > 0.0, "cost": int(spec["cost"]) + int(foundation_extra * extra),
		"type": spec["type"],
	}


func place_at(x: float, z: float, yaw: float, pitch: float, then_aim := true) -> bool:
	if brush.ground_busy or brush.painting:
		return false
	var check := check_spot(x, z)
	if not check["ok"] or brush.money < float(check["cost"]):
		return false
	commit_pending_aim()
	brush.money -= float(check["cost"])
	var tower := _create_tower(check, yaw, pitch)
	tower["plane"] = check["plane"]
	tower["patch"] = {}
	towers.append(tower)
	var center: Vector3 = tower["center"]
	terrain.add_ground_lock(center.x, center.z)
	var pad_before := PackedFloat32Array()
	# Terrain stays fixed during a battle, so a tower built then settles in when the wave ends.
	if paths.phase == paths.Phase.BUILD:
		pad_before = _shape_pad(tower)
	var cleared_trees := _clear_trees(tower)
	brush.history.record("建造" + String(tower["spec"]["name"]),
			_undo_build.bind(tower, float(check["cost"]), cleared_trees, pad_before),
			brush.discard_cleared_trees.bind(cleared_trees))
	if paths.phase == paths.Phase.BUILD:
		_after_ground_change(x, z)
	_set_mode(Mode.IDLE)
	select(tower)
	if then_aim:
		start_aiming()
	return true


## The tower's own lock has to lift for this. Other towers keep theirs, so their ground stays put.
func _shape_pad(tower: Dictionary) -> PackedFloat32Array:
	var center: Vector3 = tower["center"]
	terrain.remove_ground_lock(center.x, center.z)
	tower["patch"] = terrain.shape_tower_pad(tower["plane"], PAD_INNER, PAD_OUTER)
	var starts: PackedFloat32Array = tower["patch"]["starts"]
	tower["patch"].erase("starts")
	terrain.add_ground_lock(center.x, center.z)
	terrain.upload_state()
	return starts


## Applies ground changes held back during the battle, before the route is worked out again.
func _on_battle_ended() -> void:
	commit_pending_aim()
	for patch in pending_removals:
		terrain.remove_tower_pad(patch)
	pending_removals.clear()
	for tower in towers:
		if tower["patch"].is_empty():
			_shape_pad(tower)
	terrain.upload_state()
	brush._refresh_water_if_needed()
	brush._sync_followers(Vector2.ZERO, 0.0, true)


func _clear_trees(tower: Dictionary) -> Array:
	var cleared := []
	var center: Vector3 = tower["center"]
	var normal: Vector3 = tower["normal"]
	for along: float in [0.0, TOWER_HEIGHT * 0.5, TOWER_HEIGHT]:
		var point := center + normal * along
		cleared.append_array(brush.clear_trees_near(point.x, point.z, FOOTPRINT + 2.5))
	return cleared


func _undo_build(tower: Dictionary, cost: float, trees: Array, pad_before: PackedFloat32Array) -> void:
	_remove_live_tower(tower, false, pad_before)
	brush.money += cost
	brush.restore_cleared_trees(trees)


## During battle the route stays as it was, and is worked out afresh when the wave ends.
func _after_ground_change(x: float, z: float) -> void:
	brush._refresh_water_if_needed()
	brush._sync_followers(Vector2(x, z), PAD_OUTER + 2.0, false)
	if paths.phase == paths.Phase.BUILD:
		brush.terrain_changed.emit()


func _create_tower(check: Dictionary, yaw: float, pitch: float) -> Dictionary:
	var spec: Dictionary = specs[check["type"]]
	var normal: Vector3 = check["normal"]
	var base: Vector3 = check["base"]
	var holder := Node3D.new()
	holder.transform = Transform3D(_up_basis(normal, aim_vector(yaw, pitch)), base)
	add_child(holder)
	# The foundation: a stone drum set into the ground, ringed with boulders, square to the slope.
	# Rougher ground gets a deeper drum, so it still reaches the ground on every side.
	var stone := Props.solid(Props.STONE, 0.18, 2.0)
	var roughness: float = check["roughness"]
	var depth := PLINTH_HEIGHT + PLINTH_DEPTH + roughness * 1.2
	var footing := CylinderMesh.new()
	footing.top_radius = 3.7
	footing.bottom_radius = 4.6
	footing.height = depth
	footing.radial_segments = 20
	footing.rings = 1
	footing.material = stone
	var footing_node := MeshInstance3D.new()
	footing_node.mesh = footing
	footing_node.position.y = -depth * 0.5 + 0.02
	holder.add_child(footing_node)
	var stones: Array[Dictionary] = []
	var count := 14
	for n in count:
		var a := (float(n) + rng.randf_range(-0.2, 0.2)) * TAU / float(count)
		var s := rng.randf_range(0.8, 1.15) * (1.0 + roughness * 0.18)
		var v := rng.randf_range(0.8, 1.12)
		stones.append({
			"basis": Basis(Vector3.UP, rng.randf() * TAU).scaled_local(Vector3(s, s * 0.7, s * 0.9)),
			"pos": Vector3(cos(a) * 4.3, -PLINTH_HEIGHT - 0.1, sin(a) * 4.3),
			"color": Color(v, v, v * 0.96),
		})
	Props.add_instances(holder, rock, stone, stones)
	var turret: Dictionary = TowerModels.build(holder, String(spec.get("model", "cannon")))
	_keep_off_brush_ring(holder)
	var apex: Vector3 = check["apex"]
	var aim := aim_vector(yaw, pitch)
	var id := add_core_tower(apex, aim, spec)
	var tower := {
		"id": id, "type": spec["type"], "node": holder, "yaw_node": turret["yaw"], "pitch_node": turret["pitch"], "turret": turret, "yaw": yaw, "pitch": pitch,
		"paid": check["cost"], "spec": spec, "path": [], "stars": 0, "center": check["center"], "normal": normal, "apex": apex,
		"tilt": check["tilt"], "rough": check["rough"],
	}
	_point_turret(tower)
	return tower


## Adds a tower to the core with every stat of a spec. Also used by the balance test's own towers.
func add_core_tower(apex: Vector3, aim: Vector3, spec: Dictionary) -> int:
	var id: int = core.add_tower(apex.x, apex.y, apex.z, aim.x, aim.y, aim.z, spec["half_angle"], spec["range"], spec["damage"], spec["cooldown"], spec["splash_radius"], spec["splash_targets"])
	paths.fx.tower_styles[id] = String(spec.get("model", "cannon"))
	var stats := stats_for(spec)
	core.set_tower_stats(id, stats, stats.size())
	return id


## The numbers native/path_core.h expects in set_tower_stats, in its order.
static func stats_for(spec: Dictionary) -> PackedFloat32Array:
	return PackedFloat32Array([
		spec["half_angle"], spec["range"], spec["damage"], spec["cooldown"], spec["splash_radius"], spec["splash_targets"],
		spec.get("height_reach", 0.0), spec.get("height_reach_max", 0.0), spec.get("slow", 0.0), spec.get("slow_seconds", 0.0),
		spec.get("knock_climbers", 0.0), spec.get("fire_seconds", 0.0), spec.get("fire_radius", 0.0), spec.get("fire_dps", 0.0),
		spec.get("min_range", 0.0), 1.0 if spec.get("lob", false) else 0.0, spec.get("height_damage", 0.0),
		spec.get("height_damage_max", 0.0), spec.get("shot_speed", 0.0),
	])


## A tower type's base spec with the upgrades along path applied in order, then the stars on top.
func spec_for(path: Array, stars: int, type := "normal") -> Dictionary:
	var spec: Dictionary = specs[type].duplicate()
	var options: Array = specs[type].get("upgrades", [])
	for id: String in path:
		for node: Dictionary in options:
			if node["id"] == id:
				var change: Dictionary = node["change"]
				for key: String in change:
					spec[key] = change[key]
				spec["name"] = node["name"]
				options = node.get("next", [])
				break
	spec["half_angle"] = deg_to_rad(float(spec["cone_degrees"]) * 0.5)
	spec["damage"] = float(spec["damage"]) * (1.0 + star_bonus * float(stars))
	return spec


## The whole upgrade tree of a tower type, as written in data/towers.json.
func upgrade_tree(type := "normal") -> Array:
	return specs[type].get("upgrades", [])


## What the tower can take next: branch nodes from the tree, or one star once the branches run out.
## Each entry has "id", "name", "cost" and "tip". A star's id is "star".
func next_upgrades(tower: Dictionary) -> Array:
	var options: Array = upgrade_tree(tower.get("type", "normal"))
	for id: String in tower["path"]:
		var found: Array = []
		for node: Dictionary in options:
			if node["id"] == id:
				found = node.get("next", [])
		options = found
	if not options.is_empty():
		return options
	var stars: int = tower["stars"]
	if stars < star_costs.size():
		var bonus := int(round(star_bonus * 100.0))
		return [{"id": "star", "name": "★%d" % (stars + 1), "cost": star_costs[stars], "tip": "伤害再加 %d%%" % bonus}]
	return []


## Buys an upgrade for the selected tower. Works in battle too, like building and selling.
func upgrade_selected(id: String) -> bool:
	if selected.is_empty() or brush.ground_busy or brush.painting:
		return false
	var tower := selected
	for option: Dictionary in next_upgrades(tower):
		if option["id"] != id:
			continue
		var cost := float(option["cost"])
		if brush.money < cost:
			return false
		commit_pending_aim()
		var revert := Callable()
		if brush.history.enabled:
			var timer: float = core.tower_timer(tower["id"])
			revert = _undo_upgrade.bind(tower, tower["path"].duplicate(), tower["stars"], tower["paid"], timer, cost)
		brush.money -= cost
		tower["paid"] = int(tower["paid"]) + int(cost)
		if id == "star":
			tower["stars"] = int(tower["stars"]) + 1
		else:
			tower["path"].append(id)
		_apply_spec(tower)
		if revert.is_valid():
			brush.history.record("升级" + String(option["name"]), revert)
		_refresh_selected()
		paths.fx.upgraded(tower["center"])
		upgraded.emit(tower, option["name"])
		return true
	return false


func _undo_upgrade(tower: Dictionary, old_path: Array, stars: int, paid: int, timer: float, cost: float) -> void:
	tower["path"] = old_path
	tower["stars"] = stars
	tower["paid"] = paid
	_apply_spec(tower)
	core.restore_tower_timer(tower["id"], timer)
	brush.money += cost
	if tower == selected:
		_refresh_selected()


## Gives the core and the model everything the tower's upgrades add up to.
func _apply_spec(tower: Dictionary) -> void:
	tower["spec"] = spec_for(tower["path"], tower["stars"], tower["type"])
	var stats := stats_for(tower["spec"])
	core.set_tower_stats(tower["id"], stats, stats.size())
	TowerModels.dress(tower["turret"], tower["path"], tower["stars"])
	_keep_off_brush_ring(tower["node"])


func _keep_off_brush_ring(node: Node) -> void:
	if node is VisualInstance3D:
		node.layers = Flora.LAYER_NO_DECAL
	for child in node.get_children():
		_keep_off_brush_ring(child)


## Turns the gun to match the tower's aim, whichever way the tower itself is leaning.
func _point_turret(tower: Dictionary) -> void:
	var holder: Node3D = tower["node"]
	var local: Vector3 = holder.transform.basis.inverse() * aim_vector(tower["yaw"], tower["pitch"])
	tower["yaw_node"].rotation.y = atan2(local.x, local.z)
	# A catapult arm keeps its own resting angle, since it never points at anything.
	if aimable(tower["spec"]):
		tower["pitch_node"].rotation.x = -asin(clampf(local.y, -1.0, 1.0))


func _set_tower_aim(tower: Dictionary, yaw: float, pitch: float) -> void:
	tower["yaw"] = wrapf(yaw, -PI, PI)
	tower["pitch"] = clampf(pitch, -PI * 0.5, PI * 0.5)
	var aim := aim_vector(tower["yaw"], tower["pitch"])
	core.set_tower_aim(tower["id"], aim.x, aim.y, aim.z)
	_point_turret(tower)
	if tower == selected:
		_refresh_selected()


func select(tower: Dictionary) -> void:
	if tower != selected:
		commit_pending_aim()
	selected = tower
	brush.ring_hidden = true
	_refresh_selected()
	selection_changed.emit()


func deselect() -> void:
	commit_pending_aim()
	selected = {}
	brush.ring_hidden = false
	if mode != Mode.PLACING:
		_hide_range()
	selection_changed.emit()


func _set_hint(kind: int, text: String, sub := "") -> void:
	hint_kind = kind
	hint_text = text
	hint_sub = sub


## One line for logs and tests.
func hint_line() -> String:
	return "%s / %s" % [hint_text, hint_sub]


## Everything the interface shows about the selected tower. Empty when nothing is selected.
func selected_info() -> Dictionary:
	if selected.is_empty():
		return {}
	var spec: Dictionary = selected["spec"]
	return {
		"type": selected["type"], "aimable": aimable(spec), "lob": spec.get("lob", false), "min_range": int(spec.get("min_range", 0.0)),
		"height_damage": spec.get("height_damage", 0.0), "height_damage_max": int(spec.get("height_damage_max", 0.0)),
		"name": spec["name"], "tilt": selected["tilt"], "cone_degrees": int(round(rad_to_deg(spec["half_angle"]) * 2.0)),
		"range": int(spec["range"]), "damage": int(spec["damage"]), "rate": 1.0 / float(spec["cooldown"]),
		"covered": int(core.tower_covered(selected["id"])),
		"kills": core.tower_kills(selected["id"]), "refund": int(float(selected["paid"]) * refund_rate), "splash": spec["splash_radius"], "splash_targets": spec["splash_targets"],
		"yaw_degrees": rad_to_deg(float(selected["yaw"])), "pitch_degrees": rad_to_deg(float(selected["pitch"])),
		"path": selected["path"], "stars": selected["stars"], "max_stars": star_costs.size(), "options": next_upgrades(selected),
		"range_bonus": int(spec.get("height_reach_max", 0.0)), "fire_dps": spec.get("fire_dps", 0.0), "slow": spec.get("slow", 0.0),
		"knock": spec.get("knock_climbers", 0.0) > 0.0,
	}


## Used by the aim sliders. Taking the sliders stops any aiming with the mouse.
func aim_selected_degrees(yaw_degrees: float, pitch_degrees: float) -> void:
	if slider_interrupted or selected.is_empty() or not aimable(selected["spec"]):
		return
	if mode == Mode.AIMING:
		_set_mode(Mode.IDLE)
	var before := Vector2(selected["yaw"], selected["pitch"])
	_set_tower_aim(selected, deg_to_rad(yaw_degrees), deg_to_rad(pitch_degrees))
	if slider_tower.is_empty():
		_record_aim(selected, before)


func begin_slider_aim() -> void:
	commit_pending_aim()
	slider_interrupted = false
	if not selected.is_empty():
		slider_tower = selected
		slider_start = Vector2(selected["yaw"], selected["pitch"])


func end_slider_aim(_changed: bool) -> void:
	slider_interrupted = false
	if not slider_tower.is_empty():
		_record_aim(slider_tower, slider_start)
		slider_tower = {}
	elif not selected.is_empty():
		aim_changed.emit()


func commit_pending_aim() -> void:
	if mode == Mode.AIMING:
		_set_mode(Mode.IDLE)
	if not slider_tower.is_empty():
		_record_aim(slider_tower, slider_start)
		slider_tower = {}
		slider_interrupted = true


func cancel_pending_aim() -> void:
	if mode == Mode.AIMING and not selected.is_empty():
		_set_tower_aim(selected, aim_saved_yaw, aim_saved_pitch)
		_set_mode(Mode.IDLE)
	if not slider_tower.is_empty():
		_set_tower_aim(slider_tower, slider_start.x, slider_start.y)
		slider_tower = {}
		slider_interrupted = true


func _record_aim(tower: Dictionary, before: Vector2) -> void:
	if not brush.history.enabled:
		return
	var after := Vector2(tower["yaw"], tower["pitch"])
	if not is_zero_approx(angle_difference(before.x, after.x)) or not is_equal_approx(before.y, after.y):
		brush.history.record("调整炮口方向", _set_tower_aim.bind(tower, before.x, before.y))


func start_aiming() -> void:
	if mode == Mode.AIMING or selected.is_empty() or not aimable(selected["spec"]):
		return
	commit_pending_aim()
	aim_saved_yaw = selected["yaw"]
	aim_saved_pitch = selected["pitch"]
	_set_mode(Mode.AIMING)
	# The gun holds its aim until the mouse moves, so the click that built it changes nothing.
	aim_anchor = brush.current_mouse()
	aim_following = false
	_set_hint(HINT_INFO, "移动鼠标来瞄准", "滚轮抬高或压低炮口　·　左键确定　·　Esc 取消")


func _refresh_selected() -> void:
	_show_range(selected["apex"], aim_vector(selected["yaw"], selected["pitch"]), selected["spec"], selected["id"])
	aim_changed.emit()


func _on_terrain_changed() -> void:
	if not selected.is_empty():
		_refresh_selected()


## Picking a brush tool means going back to sculpting, so it closes anything tower-related.
func _on_tool_selected() -> void:
	leave_for_other_tool()


func leave_for_other_tool() -> void:
	if mode != Mode.IDLE:
		_set_mode(Mode.IDLE)
	deselect()


## How much route a tower of this spec (the one being placed, if none is given) covers from here.
func _covered(apex: Vector3, aim: Vector3, spec := {}) -> float:
	var stats := stats_for(spec if not spec.is_empty() else place_spec())
	return core.stats_covered(apex.x, apex.y, apex.z, aim.x, aim.y, aim.z, stats, stats.size())


func sell_selected() -> void:
	if selected.is_empty() or brush.ground_busy or brush.painting:
		return
	var tower := selected
	var refund := floorf(float(tower["paid"]) * refund_rate)
	var slot := towers.find(tower)
	var park: bool = brush.history.enabled
	var pad_before := PackedFloat32Array()
	if park and not tower["patch"].is_empty():
		pad_before = terrain.capture_patch_heights(tower["patch"])
	_remove_live_tower(tower, park)
	brush.money += refund
	if park:
		brush.history.record("拆除" + String(tower["spec"]["name"]),
				_undo_sale.bind(tower, slot, refund, pad_before), _discard_tower.bind(tower))


func _remove_live_tower(tower: Dictionary, park: bool, pad_before := PackedFloat32Array()) -> void:
	if tower == selected:
		deselect()
	if park:
		core.set_tower_parked(tower["id"], 1)
		tower["node"].hide()
	else:
		_discard_tower(tower)
	paths.fx.tower_styles.erase(tower["id"])
	towers.erase(tower)
	var center: Vector3 = tower["center"]
	terrain.remove_ground_lock(center.x, center.z)
	if paths.phase == paths.Phase.BUILD:
		if not pad_before.is_empty():
			terrain.restore_cells(tower["patch"]["indices"], pad_before, tower["patch"]["rect"])
		elif not tower["patch"].is_empty():
			terrain.remove_tower_pad(tower["patch"])
		terrain.upload_state()
		_after_ground_change(center.x, center.z)
	elif not tower["patch"].is_empty():
		pending_removals.append(tower["patch"])
	last_key = PackedFloat32Array()


func _undo_sale(tower: Dictionary, slot: int, refund: float, pad_before: PackedFloat32Array) -> void:
	brush.money -= refund
	core.set_tower_parked(tower["id"], 0)
	towers.insert(slot, tower)
	tower["node"].show()
	paths.fx.tower_styles[tower["id"]] = String(tower["spec"].get("model", "cannon"))
	var center: Vector3 = tower["center"]
	if not pad_before.is_empty():
		terrain.restore_cells(tower["patch"]["indices"], pad_before, tower["patch"]["rect"])
		terrain.upload_state()
	terrain.add_ground_lock(center.x, center.z)
	_after_ground_change(center.x, center.z)
	last_key = PackedFloat32Array()


func _discard_tower(tower: Dictionary) -> void:
	kicking.erase(tower)
	core.remove_tower(tower["id"])
	tower["node"].queue_free()


func _process(delta: float) -> void:
	if not paths.battle_paused:
		_update_kicks(delta * paths.speed)
	for tower: Dictionary in towers:
		TowerModels.spin(tower["turret"], delta)
	match mode:
		Mode.PLACING:
			_update_placing()
		Mode.AIMING:
			_update_aiming()


func _update_aiming() -> void:
	if selected.is_empty():
		_set_mode(Mode.IDLE)
		return
	# The gun holds still while the mouse is on a button or slider.
	if brush.over_ui:
		return
	if not aim_following:
		if brush.current_mouse().distance_to(aim_anchor) < AIM_START_PIXELS and aim_lift == 0.0:
			return
		aim_following = true
	var apex: Vector3 = selected["apex"]
	var direction: Vector3
	if brush.has_hit and Vector3(brush.hit).distance_to(apex) > 2.0:
		direction = (Vector3(brush.hit) + Vector3.UP * 1.1 - apex).normalized()
	else:
		direction = camera.project_ray_normal(brush.current_mouse())
	var yaw := atan2(direction.x, direction.z)
	var pitch := clampf(asin(clampf(direction.y, -1.0, 1.0)) + aim_lift, -PI * 0.5, PI * 0.5)
	_set_tower_aim(selected, yaw, pitch)


func _update_placing() -> void:
	ghost.visible = brush.has_hit
	if not brush.has_hit:
		_hide_range()
		last_key = PackedFloat32Array()
		_set_hint(HINT_INFO, "把鼠标移到地面上", _cancel_text())
		return
	var x: float = brush.hit.x
	var z: float = brush.hit.z
	var spec := place_spec()
	var key := PackedFloat32Array([x, z, place_yaw, place_pitch, brush.money, float(auto_aim), float(specs.keys().find(place_type))])
	if key.size() == last_key.size():
		var change := 0.0
		for n in key.size():
			change += absf(key[n] - last_key[n])
		if change < 0.05:
			return
	last_key = key
	place_check = check_spot(x, z)
	var ok: bool = place_check["ok"]
	if not ok:
		# Still lean the ghost with the ground, so the player can see why it was refused.
		var plane: Dictionary = terrain.fit_ground_plane(x, z, FOOTPRINT)
		ghost.transform = Transform3D(_up_basis(plane["normal"], Vector3.BACK), plane["center"])
		ghost_barrel.visible = false
		ghost_material.albedo_color = GHOST_BAD
		_set_hint(HINT_BAD, String(place_check["reason"]), _cancel_text())
		_hide_range()
		return
	var apex: Vector3 = place_check["apex"]
	var normal: Vector3 = place_check["normal"]
	if auto_aim:
		_aim_placing_at_route(apex, normal)
	var aim := aim_vector(place_yaw, place_pitch)
	# Taller towers get a taller ghost.
	var stretch := _pivot(spec) / PIVOT_HEIGHT
	ghost.transform = Transform3D(_up_basis(normal, aim) * Basis.from_scale(Vector3(1.0, stretch, 1.0)), place_check["center"])
	ghost_barrel.visible = aimable(spec)
	ghost_barrel.global_transform = Transform3D(_aim_basis(aim), apex + aim * 1.7)
	var affordable: bool = brush.money >= float(place_check["cost"])
	if not affordable:
		ghost_material.albedo_color = GHOST_BAD
		_set_hint(HINT_BAD, "金币不够：需要 %d 金" % place_check["cost"], _cancel_text())
	else:
		var rough: bool = place_check["rough"]
		ghost_material.albedo_color = GHOST_WARN if rough else GHOST_OK
		var slope_text := "平地" if place_check["tilt"] < 3.0 else "坡度 %d°" % int(round(place_check["tilt"]))
		var ground_text := "地面有起伏，地基加固 %.1f 米" % place_check["roughness"] if rough else "地基平稳"
		var main_text := "%s　·　%s，%s　·　%d 金　·　覆盖路线 %d 米" % [spec["name"], slope_text, ground_text, place_check["cost"], int(_covered(apex, aim, spec))]
		var controls := "左键建造　·　滚轮转向　·　Shift + 滚轮 俯仰　·　" if aimable(spec) else "左键建造　·　"
		_set_hint(HINT_WARN if rough else HINT_OK, main_text, controls + _cancel_text())
	_show_range(apex, aim, spec)


## A new tower starts out aimed to cover as much of the enemy route as it can.
func _aim_placing_at_route(apex: Vector3, normal: Vector3) -> void:
	var stats := stats_for(place_spec())
	var best: PackedFloat32Array = core.stats_best_aim(apex.x, apex.y, apex.z, 0.0, 0.0, 1.0, stats, stats.size())
	var aim: Vector3
	if not aimable(place_spec()):
		# Nothing to aim, so the arm just faces the route, level.
		aim = Vector3(best[0], 0.0, best[2]).normalized() if best.size() == 3 and Vector2(best[0], best[2]).length() > 0.01 else Vector3.BACK
	elif best.size() == 3:
		aim = Vector3(best[0], best[1], best[2])
	else:
		# Nothing to shoot at from here, so point out from the slope and a little down.
		aim = (normal + Vector3.DOWN * 0.3).normalized()
	place_yaw = atan2(aim.x, aim.z)
	place_pitch = asin(clampf(aim.y, -1.0, 1.0))


static func _aim_basis(aim: Vector3) -> Basis:
	var side := Vector3.UP.cross(aim)
	if side.length() < 0.01:
		side = Vector3.RIGHT
	side = side.normalized()
	return Basis(side, aim.cross(side).normalized(), aim)


## Paints where shots can land on the ground and shows the cone itself in the air.
## Placing shows the base tower. A built tower shows its own upgraded cone, read from the core.
func _show_range(apex: Vector3, aim: Vector3, spec := {}, tower_id := -1) -> void:
	if spec.is_empty():
		spec = normal_spec
	var half: float = spec["half_angle"]
	var reach: float = spec["range"]
	var reach_max: float = reach + float(spec.get("height_reach_max", 0.0))
	var data: PackedByteArray
	if tower_id >= 0:
		data = core.tower_visibility(tower_id)
	else:
		var stats := stats_for(spec)
		data = core.stats_visibility(apex.x, apex.y, apex.z, aim.x, aim.y, aim.z, stats, stats.size())
	if data.size() != map_res * map_res:
		return
	range_image.set_data(map_res, map_res, false, Image.FORMAT_L8, data)
	range_texture.update(range_image)
	for material in overlay_materials:
		material.set_shader_parameter("range_on", 1.0)
		material.set_shader_parameter("range_apex", apex)
		material.set_shader_parameter("range_aim", aim)
		material.set_shader_parameter("range_cos", cos(half))
		material.set_shader_parameter("range_dist", reach_max)
		material.set_shader_parameter("range_min", float(spec.get("min_range", 0.0)))
		material.set_shader_parameter("range_flat", 1.0 if spec.get("lob", false) else 0.0)
	range_shown = true
	# A catapult throws all round, so there is no cone in the air: the ring on the ground says it all.
	cone_view.visible = aimable(spec)
	if cone_view.visible:
		cone_view.mesh = _cone_mesh(half, reach + _height_bonus(apex, aim, spec, reach), float(spec.get("min_range", 0.0)))
		cone_view.global_transform = Transform3D(_aim_basis(aim), apex)


func _hide_range() -> void:
	if not range_shown:
		return
	range_shown = false
	cone_view.visible = false
	for material in overlay_materials:
		material.set_shader_parameter("range_on", 0.0)


## Roughly how much farther a tower that gains range from height reaches along its aim, so the cone
## drawn in the air matches the ground it can hit.
func _height_bonus(apex: Vector3, aim: Vector3, spec: Dictionary, reach: float) -> float:
	var per_metre: float = spec.get("height_reach", 0.0)
	if per_metre <= 0.0:
		return 0.0
	var flat := Vector2(aim.x, aim.z)
	if flat.length() < 0.01:
		return 0.0
	var spot := Vector2(apex.x, apex.z) + flat.normalized() * reach
	var drop: float = apex.y - terrain.height_at(spot.x, spot.y)
	return clampf(drop * per_metre, 0.0, float(spec.get("height_reach_max", 0.0)))


## The key that started placing this tower type also stops it.
func _cancel_text() -> String:
	return "%s 或 Esc 取消" % String(place_spec().get("key", "T"))


## Starts a tower's firing motion: guns kick back along the barrel, a catapult arm swings over.
func _on_tower_fired(id: int) -> void:
	for tower: Dictionary in towers:
		if tower["id"] != id:
			continue
		var pitch_node: Node3D = tower["pitch_node"]
		if not tower.has("rest_position"):
			tower["rest_position"] = pitch_node.position
			tower["rest_angle"] = pitch_node.rotation.x
		tower["kick"] = 0.0
		if not kicking.has(tower):
			kicking.append(tower)
		return


## Plays each firing motion on, in battle time, and puts the gun back at rest when it is over.
func _update_kicks(dt: float) -> void:
	for n in range(kicking.size() - 1, -1, -1):
		var tower: Dictionary = kicking[n]
		var pitch_node: Node3D = tower["pitch_node"]
		if not is_instance_valid(pitch_node):
			kicking.remove_at(n)
			continue
		tower["kick"] = float(tower["kick"]) + dt
		var style := String(tower["spec"].get("model", "cannon"))
		var motion: Dictionary = paths.fx.recoil(style)
		var t: float = tower["kick"]
		var rest_position: Vector3 = tower["rest_position"]
		var rest_angle: float = tower["rest_angle"]
		var done := false
		if style == "catapult":
			# A fast throw over the top, then a slow wind back down.
			var throw_time: float = motion.get("throw_seconds", 0.16)
			var back_time: float = motion.get("return_seconds", 1.2)
			var swing: float = motion.get("swing", -1.3)
			var angle := rest_angle
			if t < throw_time:
				var p := t / throw_time
				angle = lerpf(rest_angle, swing, 1.0 - (1.0 - p) * (1.0 - p))
			else:
				var p := minf((t - throw_time) / back_time, 1.0)
				angle = lerpf(swing, rest_angle, p * p * (3.0 - 2.0 * p))
				done = p >= 1.0
			pitch_node.rotation.x = angle
		else:
			# Snap back along the barrel at once, then ease forward again.
			var seconds: float = motion.get("seconds", 0.3)
			var p := minf(t / seconds, 1.0)
			var push := pow(1.0 - p, 2.0)
			var along := pitch_node.transform.basis.z.normalized()
			pitch_node.position = rest_position - along * float(motion.get("back", 0.6)) * push
			var local: Vector3 = tower["node"].transform.basis.inverse() * aim_vector(tower["yaw"], tower["pitch"])
			pitch_node.rotation.x = -asin(clampf(local.y, -1.0, 1.0)) - float(motion.get("lift", 0.0)) * push
			done = p >= 1.0
		if done:
			pitch_node.position = rest_position
			kicking.remove_at(n)
