extends Node
## Terrain brush: mouse input, brush ring, cost and undo.

const TerrainData = preload("res://scripts/terrain_data.gd")
const TOOL_INFO := [
	{"id": TerrainData.TOOL_RAISE, "name": "增高", "key": KEY_Q, "letter": "Q", "icon": "raise", "tip": "按住左键抬高地面，敌人遇到高山可能绕路"},
	{"id": TerrainData.TOOL_LOWER, "name": "下挖", "key": KEY_E, "letter": "E", "icon": "lower", "tip": "按住左键挖低地面，深坑会逼敌人搭桥或爬行"},
	{"id": TerrainData.TOOL_SMOOTH, "name": "平滑", "key": KEY_R, "letter": "R", "icon": "smooth", "tip": "让地面的起伏变得柔和"},
	{"id": TerrainData.TOOL_FLATTEN, "name": "压平", "key": KEY_F, "letter": "F", "icon": "flatten", "tip": "把地面压到落笔处的高度"},
	{"id": TerrainData.TOOL_SLOPE, "name": "斜面", "key": KEY_H, "letter": "H", "icon": "slope", "tip": "保留落笔处的坡度，抹平凹凸，做成斜着的平台"},
	{"id": TerrainData.TOOL_PINCH, "name": "挤压", "key": KEY_G, "letter": "G", "icon": "pinch", "tip": "把地形向中心挤拢，按住 Shift 则向外拉开"},
]

## Sent after a stroke or undo finishes, once the terrain and water are up to date.
signal terrain_changed
## Sent when the player picks a brush tool, which means going back to sculpting.
signal tool_selected

var terrain
var camera: Camera3D
var water_node: MeshInstance3D
var feel: Node
## Prices and limits from data/terrain_tools.json.
var cost_per_cubic_metre := 0.15
var raise_rate := 5.5
var smooth_rate := 6.0
var flatten_rate := 5.0
var pinch_rate := 5.0
var max_undo := 20
var min_radius := 3.0
## Larger brushes cost too much script time per frame to hold the frame rate.
var max_radius := 40.0
## Pinching resamples every point in the brush, so it needs a smaller limit.
var max_pinch_radius := 26.0
var min_strength := 0.2
var max_strength := 3.0
var fall_seconds := 0.8
var flood_fill_seconds := 1.4
## Seconds since new water began to flow. Large means nothing is flowing.
var flood_clock := 10000.0
## True during battle, when terrain can no longer be edited.
var locked := false
## True while tower placement is using the mouse.
var paused := false
## True while the preset tools are using the mouse.
var tools_busy := false
## True while ready-made terrain is rising, when nothing else may change the ground.
var ground_busy := false
## True while a tower is selected, when a click on the ground closes its panel instead of painting.
var ring_hidden := false
## True while the mouse is over a button or panel rather than the world.
var over_ui := false
var followers: Array[Node3D] = []
var hides_on_bare_ground := {}

var tool: int = TerrainData.TOOL_LOWER
var radius := 14.0
var strength := 1.0
var money := 0.0
var painting := false
var flatten_height := 0.0
var has_hit := false
var hit := Vector3.ZERO
## Replaces the real cursor during the automated test, so it never moves the user's mouse.
var test_mouse: Variant = null

var undo_stack: Array[Dictionary] = []
var stroke_saved := PackedFloat32Array()
var stroke_money := 0.0
var stroke_rect := Rect2i()

var ring: Decal

# Timing of the most recent painted frame, in milliseconds.
var last_edit_ms := 0.0
var last_upload_ms := 0.0
var last_water_ms := 0.0
var last_follow_ms := 0.0


func setup(data, view_camera: Camera3D, water: MeshInstance3D, trees: Array[Node3D], lanterns: Array[Node3D], tools_config: Dictionary, start_money: float, feel_node: Node) -> void:
	terrain = data
	camera = view_camera
	water_node = water
	feel = feel_node
	money = start_money
	cost_per_cubic_metre = tools_config["cost_per_cubic_metre"]
	var rates: Dictionary = tools_config["brush"]
	raise_rate = rates["raise_rate"]
	smooth_rate = rates["smooth_rate"]
	flatten_rate = rates["flatten_rate"]
	pinch_rate = rates["pinch_rate"]
	max_undo = rates["max_undo"]
	min_radius = rates["min_radius"]
	max_radius = rates["max_radius"]
	max_pinch_radius = rates["max_pinch_radius"]
	min_strength = rates["min_strength"]
	max_strength = rates["max_strength"]
	fall_seconds = tools_config["feel"]["tree_fall_seconds"]
	flood_fill_seconds = tools_config["feel"]["flood_fill_seconds"]
	terrain.flood_speed = tools_config["feel"]["flood_speed"]
	water_node.material_override.set_shader_parameter("flood_fill_seconds", flood_fill_seconds)
	for tree in trees:
		followers.append(tree)
		hides_on_bare_ground[tree] = true
	for lantern in lanterns:
		followers.append(lantern)
	_build_ring()


func _build_ring() -> void:
	var gradient := Gradient.new()
	# Emission adds light, so black is invisible. Alpha plays no part in this texture.
	gradient.offsets = PackedFloat32Array([0.0, 0.93, 0.96, 0.985, 1.0])
	gradient.colors = PackedColorArray([Color.BLACK, Color.BLACK, Color.WHITE, Color.BLACK, Color.BLACK])
	var texture := GradientTexture2D.new()
	texture.width = 512
	texture.height = 512
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	ring = Decal.new()
	ring.cull_mask = 3
	ring.texture_emission = texture
	ring.emission_energy = 1.3
	ring.modulate = Color(1.0, 0.92, 0.7)
	ring.albedo_mix = 0.0
	ring.upper_fade = 0.05
	ring.lower_fade = 0.05
	ring.visible = false
	add_child(ring)


## Stops following the real cursor, so the ring stays out of screenshots and measurements.
func hide_for_capture() -> void:
	set_process(false)
	ring.visible = false


func select_tool(id: int) -> void:
	tool = id
	_pick_slope()
	tool_selected.emit()


## The slope tool keeps whatever slope the ground has under the brush when the stroke starts.
func _pick_slope() -> void:
	if tool == TerrainData.TOOL_SLOPE and has_hit:
		terrain.brush_plane = terrain.fit_ground_plane(hit.x, hit.z, radius)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				begin_stroke()
			else:
				end_stroke()
			get_viewport().set_input_as_handled()
		elif event.pressed and (event.ctrl_pressed or event.alt_pressed):
			var change := 0.0
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				change = 1.1
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				change = 1.0 / 1.1
			if change > 0.0:
				if event.ctrl_pressed:
					radius = clampf(radius * change, min_radius, max_radius)
				else:
					strength = clampf(strength * change, min_strength, max_strength)
				get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_Z and event.ctrl_pressed:
			undo()
			get_viewport().set_input_as_handled()
			return
		for entry: Dictionary in TOOL_INFO:
			if event.physical_keycode == entry["key"] and not locked:
				select_tool(entry["id"])
				get_viewport().set_input_as_handled()


func begin_stroke() -> void:
	if not has_hit or locked or paused or tools_busy or ground_busy:
		return
	painting = true
	stroke_saved = terrain.heights.duplicate()
	stroke_money = money
	stroke_rect = Rect2i()
	flatten_height = terrain.height_at(hit.x, hit.z)
	_pick_slope()


func end_stroke() -> void:
	if not painting:
		return
	painting = false
	if stroke_rect.has_area():
		undo_stack.append({"heights": stroke_saved, "money": stroke_money, "rect": stroke_rect})
		if undo_stack.size() > max_undo:
			undo_stack.pop_front()
	var changed := stroke_rect.has_area()
	stroke_saved = PackedFloat32Array()
	_refresh_water_if_needed()
	if changed:
		terrain_changed.emit()


## Undo would bring back old money and old ground, so it stops at battles and new towers.
func clear_undo() -> void:
	undo_stack.clear()


## Trees standing where something is built topple, then are gone for good.
func clear_trees_near(x: float, z: float, distance: float) -> void:
	for node: Node3D in followers.duplicate():
		if hides_on_bare_ground.has(node) and Vector2(node.position.x - x, node.position.z - z).length() < distance:
			followers.erase(node)
			hides_on_bare_ground.erase(node)
			_topple(node, Vector2(node.position.x - x, node.position.z - z), true)


## Tips a tree over away from the given direction, and shrinks it into the ground as it lands.
func _topple(tree: Node3D, away: Vector2, remove: bool) -> void:
	tree.set_meta("down", true)
	var direction := away.normalized() if away.length() > 0.01 else Vector2.RIGHT
	# Euler angles apply the tree's own turn last, so the fall is worked out in its turned frame.
	var local := Vector3(direction.x, 0.0, direction.y).rotated(Vector3.UP, -tree.rotation.y)
	if tree.has_meta("motion"):
		var old: Tween = tree.get_meta("motion")
		if old.is_valid():
			old.kill()
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(tree, "rotation:x", local.z * 1.45, fall_seconds)
	tween.parallel().tween_property(tree, "rotation:z", -local.x * 1.45, fall_seconds)
	tween.tween_property(tree, "scale", Vector3.ONE * 0.01, 0.25).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(tree.queue_free if remove else tree.hide)
	tree.set_meta("motion", tween)


## A tree comes back where the ground can hold it again.
func _regrow(tree: Node3D) -> void:
	tree.set_meta("down", false)
	if tree.has_meta("motion"):
		var old: Tween = tree.get_meta("motion")
		if old.is_valid():
			old.kill()
	tree.visible = true
	tree.rotation.x = 0.0
	tree.rotation.z = 0.0
	var full: float = tree.get_meta("full_scale", 1.0)
	tree.scale = Vector3.ONE * 0.05
	var tween := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(tree, "scale", Vector3.ONE * full, 0.5)
	tree.set_meta("motion", tween)


## Called by anything that has finished moving the ground.
func finish_ground_change() -> void:
	terrain.upload_state()
	_refresh_water_if_needed()
	_sync_followers(Vector2.ZERO, 0.0, true)
	terrain_changed.emit()


func sync_followers_near(center: Vector2, reach: float) -> void:
	_sync_followers(center, reach, false)


func current_mouse() -> Vector2:
	return get_viewport().get_mouse_position() if test_mouse == null else test_mouse


## The radius the current tool really uses.
func effective_radius() -> float:
	return minf(radius, max_pinch_radius) if tool == TerrainData.TOOL_PINCH else radius


func undo() -> void:
	if undo_stack.is_empty() or painting or locked or ground_busy:
		return
	var entry: Dictionary = undo_stack.pop_back()
	var rect: Rect2i = entry["rect"]
	if entry.has("undo"):
		entry["undo"].call()
	else:
		terrain.restore_heights(entry["heights"], rect)
	money = entry["money"]
	terrain.upload_state()
	_refresh_water_if_needed()
	_sync_followers(Vector2(rect.get_center()), 0.0, true)
	terrain_changed.emit()


func _refresh_water_if_needed() -> void:
	if not terrain.water_dirty:
		return
	var begin := Time.get_ticks_usec()
	terrain.refresh_water()
	water_node.mesh = terrain.build_water_mesh()
	if terrain.flood_started:
		flood_clock = 0.0
	last_water_ms = float(Time.get_ticks_usec() - begin) / 1000.0


func _process(delta: float) -> void:
	_update_hit()
	if flood_clock < 120.0:
		flood_clock += delta
	water_node.material_override.set_shader_parameter("flood_clock", flood_clock)
	if painting and has_hit:
		paint(tool, hit.x, hit.z, radius, strength, delta, Input.is_key_pressed(KEY_SHIFT))
		if tool != TerrainData.TOOL_SMOOTH:
			feel.shake(hit, effective_radius(), 0.45 + strength * 0.2)


func _update_hit() -> void:
	var mouse: Vector2 = get_viewport().get_mouse_position() if test_mouse == null else test_mouse
	# Buttons and panels sit above the world, so the ground under them is out of reach.
	over_ui = test_mouse == null and get_viewport().gui_get_hovered_control() != null
	var result: Variant = null if over_ui else terrain.raycast(camera.project_ray_origin(mouse), camera.project_ray_normal(mouse))
	has_hit = result != null
	if has_hit:
		hit = result
	ring.visible = has_hit and not locked and not paused and not tools_busy and not ring_hidden
	if has_hit:
		ring.position = Vector3(hit.x, hit.y, hit.z)
		var shown := effective_radius()
		ring.size = Vector3(shown * 2.0, 140.0, shown * 2.0)


## Runs one frame of the current brush. Holding shift reverses raise, lower and pinch.
func paint(id: int, x: float, z: float, brush_radius: float, power: float, delta: float, reverse := false) -> void:
	if money <= 0.0:
		return
	var amount := 0.0
	var real_tool := id
	if id == TerrainData.TOOL_PINCH:
		brush_radius = minf(brush_radius, max_pinch_radius)
	match id:
		TerrainData.TOOL_RAISE:
			amount = raise_rate * power * delta * (-1.0 if reverse else 1.0)
		TerrainData.TOOL_LOWER:
			amount = -raise_rate * power * delta * (-1.0 if reverse else 1.0)
		TerrainData.TOOL_SMOOTH:
			amount = smooth_rate * power * delta
		TerrainData.TOOL_FLATTEN, TerrainData.TOOL_SLOPE:
			amount = flatten_rate * power * delta
		TerrainData.TOOL_PINCH:
			amount = pinch_rate * power * delta * (-1.0 if reverse else 1.0)
	var begin := Time.get_ticks_usec()
	var result: Dictionary = terrain.apply_brush(real_tool, x, z, brush_radius, amount, flatten_height)
	var after_edit := Time.get_ticks_usec()
	terrain.upload_state()
	var after_upload := Time.get_ticks_usec()
	_sync_followers(Vector2(x, z), brush_radius, false)
	var after_follow := Time.get_ticks_usec()
	last_edit_ms = float(after_edit - begin) / 1000.0
	last_upload_ms = float(after_upload - after_edit) / 1000.0
	last_follow_ms = float(after_follow - after_upload) / 1000.0
	money = maxf(money - float(result["volume"]) * cost_per_cubic_metre, 0.0)
	var rect: Rect2i = result["rect"]
	if rect.has_area():
		stroke_rect = stroke_rect.merge(rect) if stroke_rect.has_area() else rect


## Trees and lanterns stay on the ground. Trees topple where the ground no longer holds them.
func _sync_followers(center: Vector2, brush_radius: float, everywhere: bool) -> void:
	var reach := (brush_radius + 2.0) * (brush_radius + 2.0)
	for node in followers:
		var p := node.position
		if not everywhere and Vector2(p.x - center.x, p.z - center.y).length_squared() > reach:
			continue
		var ground: float = terrain.height_at(p.x, p.z)
		node.position.y = ground
		if hides_on_bare_ground.has(node):
			var normal: Vector3 = terrain.normal_at(p.x, p.z)
			var holds: bool = ground > terrain.WATER_LEVEL + 0.6 and terrain.dig_at(p.x, p.z) < 1.2 and normal.y > 0.5
			var down: bool = node.get_meta("down", false)
			if not node.has_meta("full_scale"):
				node.set_meta("full_scale", node.scale.x)
			if not holds and not down:
				# It falls downhill, or away from the brush on level ground.
				var away := Vector2(normal.x, normal.z)
				_topple(node, away if away.length() > 0.05 else Vector2(p.x - center.x, p.z - center.y), false)
			elif holds and down:
				_regrow(node)


## Automated sculpting used to measure performance and capture before and after images.
## Each step paints along a line for a set time, exactly as a held mouse button would.
func run_test(main: Node3D, dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	main.apply_view("strategy")
	set_process(false)
	# The measurements should not stop because the budget ran out.
	money = 10000000.0
	await get_tree().create_timer(9.0).timeout
	await _test_shot(dir, "0_before")
	await _test_input(dir)
	set_process(false)
	var pit: Vector2 = terrain.pit_center()
	var steps: Array[Dictionary] = [
		{"name": "1_raise_mountain", "tool": TerrainData.TOOL_RAISE, "from": Vector2(-34.0, 58.0), "to": Vector2(-34.0, 58.0), "radius": 24.0, "power": 1.3, "time": 4.0},
		{"name": "2_channel_to_pit", "tool": TerrainData.TOOL_LOWER, "from": Vector2(30.0, -14.0), "to": pit + Vector2(12.0, 4.0), "radius": 6.0, "power": 1.4, "time": 6.0},
		{"name": "3_trench_across_path", "tool": TerrainData.TOOL_LOWER, "from": Vector2(-30.0, 40.0), "to": Vector2(36.0, 62.0), "radius": 9.0, "power": 1.2, "time": 5.0},
		{"name": "4_flatten_terrace", "tool": TerrainData.TOOL_FLATTEN, "from": Vector2(112.0, 30.0), "to": Vector2(112.0, 30.0), "radius": 18.0, "power": 1.0, "time": 2.5},
		{"name": "5_pinch_mountain", "tool": TerrainData.TOOL_PINCH, "from": Vector2(-34.0, 58.0), "to": Vector2(-34.0, 58.0), "radius": max_pinch_radius, "power": 1.0, "time": 2.0},
		{"name": "6_smooth_trench", "tool": TerrainData.TOOL_SMOOTH, "from": Vector2(-20.0, 43.0), "to": Vector2(20.0, 56.0), "radius": 10.0, "power": 1.0, "time": 3.0},
		{"name": "7_wide_brush_stress", "tool": TerrainData.TOOL_RAISE, "from": Vector2(90.0, 90.0), "to": Vector2(90.0, 50.0), "radius": max_radius, "power": 0.3, "time": 3.0},
	]
	for step: Dictionary in steps:
		await _test_step(dir, step)
	# Undo everything, then confirm the terrain matches its starting state.
	while not undo_stack.is_empty():
		undo()
	var mismatch := 0.0
	for i in terrain.heights.size():
		mismatch = maxf(mismatch, absf(terrain.heights[i] - terrain.start_heights[i]))
	print("BRUSH undo all: max height difference %.4f, money %d, water cells %d of %d" % [mismatch, int(money), terrain.water_cells.size(), terrain.start_water_cells.size()])
	await get_tree().create_timer(3.0).timeout
	await _test_shot(dir, "8_after_undo")
	get_tree().quit()


## Sends real input events through the same path as a player's mouse and keyboard.
func _test_input(dir: String) -> void:
	set_process(true)
	test_mouse = get_viewport().get_visible_rect().size * 0.5
	await get_tree().process_frame
	var saved: PackedFloat32Array = terrain.heights.duplicate()
	var money_before := money
	var key := InputEventKey.new()
	key.physical_keycode = KEY_Q
	key.pressed = true
	Input.parse_input_event(key)
	await get_tree().process_frame
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.ctrl_pressed = true
	wheel.position = test_mouse
	var radius_before := radius
	Input.parse_input_event(wheel)
	await get_tree().process_frame
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = test_mouse
	Input.parse_input_event(press)
	await get_tree().create_timer(1.5).timeout
	await _test_shot(dir, "input_ring")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = test_mouse
	Input.parse_input_event(release)
	await get_tree().process_frame
	await get_tree().process_frame
	var changed := 0.0
	for i in saved.size():
		changed = maxf(changed, terrain.heights[i] - saved[i])
	print("BRUSH input: tool raise %s, radius %.1f to %.1f, hit %s, ring %s, raised %.2f m, spent %d, undo entries %d" % [
		tool == TerrainData.TOOL_RAISE, radius_before, radius, has_hit, ring.visible, changed, int(money_before - money), undo_stack.size(),
	])
	var undo_key := InputEventKey.new()
	undo_key.physical_keycode = KEY_Z
	undo_key.pressed = true
	undo_key.ctrl_pressed = true
	Input.parse_input_event(undo_key)
	await get_tree().process_frame
	await get_tree().process_frame
	var left := 0.0
	for i in saved.size():
		left = maxf(left, absf(terrain.heights[i] - saved[i]))
	print("BRUSH input undo: max height difference %.4f, money restored %s" % [left, is_equal_approx(money, money_before)])
	test_mouse = null
	ring.visible = false


func _test_step(dir: String, step: Dictionary) -> void:
	has_hit = true
	hit = Vector3(step["from"].x, 0.0, step["from"].y)
	begin_stroke()
	var from: Vector2 = step["from"]
	var to: Vector2 = step["to"]
	var duration: float = step["time"]
	var elapsed := 0.0
	var money_before := money
	var frames := 0
	var edit_total := 0.0
	var edit_max := 0.0
	var upload_total := 0.0
	var follow_total := 0.0
	var frame_total := 0.0
	var frame_max := 0.0
	var previous := Time.get_ticks_usec()
	while elapsed < duration:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := float(now - previous) / 1000.0
		previous = now
		var delta := frame_ms / 1000.0
		elapsed += delta
		var p := from.lerp(to, clampf(elapsed / duration, 0.0, 1.0))
		paint(step["tool"], p.x, p.y, step["radius"], step["power"], delta)
		frames += 1
		edit_total += last_edit_ms
		edit_max = maxf(edit_max, last_edit_ms)
		upload_total += last_upload_ms
		follow_total += last_follow_ms
		frame_total += frame_ms
		frame_max = maxf(frame_max, frame_ms)
	end_stroke()
	var count := float(maxi(frames, 1))
	print("BRUSH %s radius %.0f: frames %d, frame avg %.1f ms (%.0f fps) max %.1f; edit avg %.2f max %.2f; upload avg %.2f; followers avg %.3f; water refresh %.1f ms; cost %d" % [
		step["name"], step["radius"], frames, frame_total / count, 1000.0 * count / frame_total, frame_max,
		edit_total / count, edit_max, upload_total / count, follow_total / count, last_water_ms, int(money_before - money),
	])
	last_water_ms = 0.0
	await get_tree().create_timer(1.5).timeout
	await _test_shot(dir, step["name"])


func _test_shot(dir: String, name_text: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name_text])
