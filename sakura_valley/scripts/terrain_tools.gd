extends Node
## Ready-made terrain: hills, ridges, pits and tunnels. All their numbers are in data/terrain_tools.json.
## A tunnel cannot be part of a height map, so it is a link between two doors, with a dark doorway at each end.

const Props = preload("res://scripts/props.gd")
const Flora = preload("res://scripts/flora.gd")

## Sent when the active tool, the selected tunnel or the set of tunnels changes.
signal state_changed

enum { HINT_INFO, HINT_OK, HINT_WARN, HINT_BAD }

const GHOST_RAISE := Color(0.62, 0.82, 0.55, 0.5)
const GHOST_DIG := Color(0.82, 0.62, 0.4, 0.5)
const GHOST_BAD := Color(0.88, 0.48, 0.42, 0.55)
const TURN_STEP := PI / 12.0
const TUNNEL_ID := "tunnel"
const PORTAL_PICK_DISTANCE := 7.0
const GAP_POST_HEIGHT := 26.0
## Angles a fitting ridge tries, spread over half a circle, and how much shorter another angle must be
## before it replaces the current one.
const TURN_TRIES := 12
const TURN_KEEP_METRES := 6.0
## How many slider steps one wheel notch moves a preset size.
const WHEEL_STEPS := 2.0

var terrain
var camera: Camera3D
var brush: Node
var paths: Node
var towers: Node
var feel: Node
var rock: Mesh
var rng := RandomNumberGenerator.new()
var config: Dictionary
var presets: Array = []
var cost_per_cubic_metre := 0.15

## Id of the preset being placed, the tunnel tool's id, or empty.
var active_id := ""
var active_preset := {}
var yaw := 0.0
## Set once the player turns a ridge with the wheel. Until then a fitting ridge picks its own angle.
var yaw_by_hand := false
## The sizes the player picked for each preset, by preset id, then by setting key such as "length".
var sizes := {}
## Whether a ridge with "fit_ends" stretches to the hillsides by itself. Dragging its length turns this off.
var stretch := true
## How long the ridge in the current preview is, so the length slider can show what stretching chose.
var preview_length := 0.0
var tunnel_start := Vector2.INF
var tunnel_plan := {}
var job := {}
var tunnels: Array[Dictionary] = []
var selected_tunnel := {}

var ghost: MeshInstance3D
var ghost_material: StandardMaterial3D
## Red posts at the ends of a ridge that did not reach high ground, where enemies could walk round.
var gap_markers: Array[Node3D] = []
## World points of the open ends in the current preview.
var preview_open: Array = []
var last_key := PackedFloat32Array()
var preview_cost := 0
var preview_ok := false
## What the interface should tell the player right now. Empty means nothing to say.
var hint_text := ""
var hint_sub := ""
var hint_kind := HINT_INFO


func setup(data, view_camera: Camera3D, brush_node: Node, path_node: Node, tower_node: Node, feel_node: Node, tools_config: Dictionary) -> void:
	terrain = data
	camera = view_camera
	brush = brush_node
	paths = path_node
	towers = tower_node
	feel = feel_node
	config = tools_config
	presets = config["presets"]
	for preset: Dictionary in presets:
		var picked := {}
		for setting: Dictionary in preset.get("adjust", []):
			picked[setting["key"]] = float(preset[setting["key"]])
		sizes[preset["id"]] = picked
	cost_per_cubic_metre = config["cost_per_cubic_metre"]
	rock = Props.make_rock_mesh(23)
	rng.seed = 9091
	ghost_material = StandardMaterial3D.new()
	ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	ghost_material.no_depth_test = true
	ghost_material.albedo_color = GHOST_RAISE
	ghost = MeshInstance3D.new()
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ghost.visible = false
	add_child(ghost)
	for n in 2:
		var marker := _make_gap_marker()
		gap_markers.append(marker)
		add_child(marker)
	brush.tool_selected.connect(cancel)
	towers.selection_changed.connect(func() -> void:
		if not towers.selected.is_empty():
			deselect_tunnel())



## Every button in the preset row: the presets, then the tunnel tool.
func tool_list() -> Array:
	var list: Array = presets.duplicate()
	var tunnel: Dictionary = config["tunnel"].duplicate()
	tunnel["id"] = TUNNEL_ID
	list.append(tunnel)
	return list


## The settings a preset lets the player change, with their ranges, from data/terrain_tools.json.
func adjust_list(id: String) -> Array:
	for preset: Dictionary in presets:
		if preset["id"] == id:
			return preset.get("adjust", [])
	return []


## A preset with the player's sizes in place of the defaults.
func shaped(preset: Dictionary) -> Dictionary:
	var result := preset.duplicate()
	var picked: Dictionary = sizes.get(preset["id"], {})
	for key: String in picked:
		result[key] = picked[key]
	return result


## Changes one size of the active preset. Choosing a ridge's length by hand stops it stretching.
func set_size(key: String, value: float) -> void:
	if active_preset.is_empty():
		return
	for setting: Dictionary in adjust_list(active_id):
		if setting["key"] == key:
			value = clampf(snappedf(value, float(setting["step"])), float(setting["min"]), float(setting["max"]))
	sizes[active_id][key] = value
	if key == "length" and active_preset.get("fit_ends", false):
		stretch = false
	last_key = PackedFloat32Array()
	state_changed.emit()


## Turns a ridge's stretching to the hillsides on or off.
func set_stretch(on: bool) -> void:
	stretch = on
	if on:
		yaw_by_hand = false
	last_key = PackedFloat32Array()
	state_changed.emit()


## Whether the active preset is stretching itself right now.
func stretching() -> bool:
	return stretch and active_preset.get("fit_ends", false)


## Nudges the setting tied to a wheel modifier ("ctrl" or "alt") by a few steps.
func _wheel_size(modifier: String, up: bool) -> bool:
	for setting: Dictionary in adjust_list(active_id):
		if setting.get("wheel", "") == modifier:
			var key: String = setting["key"]
			var current: float = sizes[active_id][key]
			if key == "length" and stretching():
				current = preview_length
			set_size(key, current + float(setting["step"]) * WHEEL_STEPS * (1.0 if up else -1.0))
			return true
	return false


func activate(id: String) -> void:
	if brush.locked or not job.is_empty():
		return
	if active_id == id:
		cancel()
		return
	towers.leave_for_other_tool()
	deselect_tunnel()
	active_id = id
	active_preset = {}
	yaw_by_hand = false
	for preset: Dictionary in presets:
		if preset["id"] == id:
			active_preset = preset
	tunnel_start = Vector2.INF
	tunnel_plan = {}
	last_key = PackedFloat32Array()
	_show_gaps([])
	brush.tools_busy = true
	state_changed.emit()


func cancel() -> void:
	if active_id == "":
		return
	active_id = ""
	active_preset = {}
	tunnel_start = Vector2.INF
	brush.tools_busy = false
	ghost.visible = false
	_show_gaps([])
	_set_hint(HINT_INFO, "")
	state_changed.emit()


func _set_hint(kind: int, text: String, sub := "") -> void:
	hint_kind = kind
	hint_text = text
	hint_sub = sub


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.ctrl_pressed:
			return
		if event.physical_keycode == KEY_ESCAPE:
			if active_id != "":
				if tunnel_start != Vector2.INF:
					tunnel_start = Vector2.INF
					last_key = PackedFloat32Array()
				else:
					cancel()
				get_viewport().set_input_as_handled()
			elif not selected_tunnel.is_empty():
				deselect_tunnel()
				get_viewport().set_input_as_handled()
			return
		for tool: Dictionary in tool_list():
			if event.as_text_physical_keycode() == String(tool["key"]):
				activate(tool["id"])
				get_viewport().set_input_as_handled()
				return
		return
	if not event is InputEventMouseButton or not event.pressed:
		return
	if active_id == "":
		if event.button_index == MOUSE_BUTTON_LEFT and not brush.locked and towers.mode == towers.Mode.IDLE:
			var tunnel := _tunnel_under_mouse()
			if not tunnel.is_empty():
				select_tunnel(tunnel)
				get_viewport().set_input_as_handled()
			elif not selected_tunnel.is_empty():
				deselect_tunnel()
				get_viewport().set_input_as_handled()
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		if brush.has_hit:
			_click(Vector2(brush.hit.x, brush.hit.z))
		get_viewport().set_input_as_handled()
	elif event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not active_preset.is_empty():
			var up: bool = event.button_index == MOUSE_BUTTON_WHEEL_UP
			if event.ctrl_pressed or event.alt_pressed:
				_wheel_size("ctrl" if event.ctrl_pressed else "alt", up)
			else:
				yaw += TURN_STEP if up else -TURN_STEP
				yaw_by_hand = true
			get_viewport().set_input_as_handled()


func _click(at: Vector2) -> void:
	if not active_preset.is_empty():
		# One placement finishes the job, so the result is not hidden behind another preview. Shift keeps going.
		if place_preset(shaped(active_preset), at, yaw, stretch) and not Input.is_key_pressed(KEY_SHIFT):
			cancel()
	elif tunnel_start == Vector2.INF:
		tunnel_start = at
		last_key = PackedFloat32Array()
	else:
		if build_tunnel(tunnel_start, at):
			cancel()


func _process(delta: float) -> void:
	if not job.is_empty():
		_advance_job(delta)
	if active_id == "":
		return
	if brush.locked or towers.mode != towers.Mode.IDLE:
		cancel()
		return
	if not brush.has_hit:
		ghost.visible = false
		_show_gaps([])
		_set_hint(HINT_INFO, "把鼠标移到地面上", "Esc 取消")
		last_key = PackedFloat32Array()
		return
	var key := PackedFloat32Array([brush.hit.x, brush.hit.z, yaw, brush.money, tunnel_start.x if tunnel_start != Vector2.INF else 0.0])
	if key.size() == last_key.size():
		var change := 0.0
		for n in key.size():
			change += absf(key[n] - last_key[n])
		if change < 0.05:
			return
	last_key = key
	if active_preset.is_empty():
		_preview_tunnel(Vector2(brush.hit.x, brush.hit.z))
	else:
		_preview_preset(active_preset, Vector2(brush.hit.x, brush.hit.z))


## Where a preset really goes when dropped at a spot. A ridge with "fit_ends" stretches until both its
## ends meet high ground, so a slightly off-centre drop still closes the road. With turn, it also tries
## other angles and takes the one that closes the gap with the shortest ridge. If no angle closes it,
## the angle stays as it was. A ridge looks the same
## turned half a circle, so half a circle of angles is enough. The given angle wins near ties, so the
## ghost does not flick between angles as the mouse moves.
func fit_preset(preset: Dictionary, at: Vector2, rotation_y: float, turn := false, grow := true) -> Dictionary:
	if not preset.get("fit_ends", false):
		return {"preset": preset, "at": at, "yaw": rotation_y, "open": []}
	var best: Dictionary = terrain.fit_ridge(preset, at.x, at.y, rotation_y, grow)
	best["yaw"] = rotation_y
	# A ridge whose length the player chose keeps the player's angle too.
	if not turn or not grow:
		return best
	var best_score := _fit_score(best) - TURN_KEEP_METRES
	for n in TURN_TRIES:
		var angle := float(n) * PI / float(TURN_TRIES)
		var fit: Dictionary = terrain.fit_ridge(preset, at.x, at.y, angle)
		# Only an angle that closes the gap is worth turning to. Otherwise the player's angle stays.
		var open: Array = fit["open"]
		if not open.is_empty():
			continue
		var score := _fit_score(fit)
		if score < best_score:
			best = fit
			best["yaw"] = angle
			best_score = score
	return best


## Fewer open ends always wins, then the shorter ridge.
func _fit_score(fit: Dictionary) -> float:
	var open: Array = fit["open"]
	return float(open.size()) * 1000.0 + float(fit["preset"]["length"])


func _preview_preset(base: Dictionary, at: Vector2) -> void:
	var preset := shaped(base)
	var fit := fit_preset(preset, at, yaw, not yaw_by_hand, stretch)
	yaw = fit["yaw"]
	var shape: Dictionary = fit["preset"]
	var middle: Vector2 = fit["at"]
	var preview: Dictionary = terrain.preview_preset(shape, middle.x, middle.y, yaw)
	preview_length = float(shape.get("length", 0.0))
	preview_cost = int(float(preview["volume"]) * cost_per_cubic_metre)
	preview_ok = float(preview["volume"]) > 1.0 and brush.money >= float(preview_cost)
	var raising := float(preset.get("height", 0.0)) > 0.0
	ghost_material.albedo_color = (GHOST_RAISE if raising else GHOST_DIG) if preview_ok else GHOST_BAD
	_draw_preview(preview["points"], preview["side"])
	preview_open = fit["open"]
	_show_gaps(preview_open if float(preview["volume"]) > 1.0 else [])
	var controls := _controls_text(preset)
	var summary := "%s　·　%d 金　·　约 %d 立方米" % [preset["name"], preview_cost, int(preview["volume"])]
	if float(preview["volume"]) <= 1.0:
		_set_hint(HINT_BAD, "这里不能改地形", "Esc 取消")
	elif brush.money < float(preview_cost):
		_set_hint(HINT_BAD, "金币不够：需要 %d 金" % preview_cost, controls)
	elif preview_open.size() == 2:
		_set_hint(HINT_WARN, "%s　·　两头都没接上高地，敌人会从红柱处绕过去" % summary, controls)
	elif preview_open.size() == 1:
		_set_hint(HINT_WARN, "%s　·　一头没接上高地，敌人会从红柱处绕过去" % summary, controls)
	elif preset.get("fit_ends", false):
		_set_hint(HINT_OK, "%s　·　两头已接上山坡" % summary, controls)
	else:
		_set_hint(HINT_OK, summary, controls)


## The second hint line while placing: which mouse and key moves do what for this preset.
func _controls_text(preset: Dictionary) -> String:
	var parts: PackedStringArray = ["左键放置"]
	if stretching() and not yaw_by_hand:
		parts.append("已自动对准路口，滚轮手动旋转")
	else:
		parts.append("滚轮旋转")
	for setting: Dictionary in preset.get("adjust", []):
		match String(setting.get("wheel", "")):
			"ctrl":
				parts.append("Ctrl + 滚轮 %s" % setting["name"])
			"alt":
				parts.append("Alt + 滚轮 %s" % setting["name"])
	parts.append("Esc 取消")
	return "　·　".join(parts)


func _make_gap_marker() -> Node3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.albedo_color = Color(GHOST_BAD, 0.8)
	var marker := Node3D.new()
	var post := MeshInstance3D.new()
	var post_mesh := CylinderMesh.new()
	post_mesh.top_radius = 1.4
	post_mesh.bottom_radius = 1.4
	post_mesh.height = GAP_POST_HEIGHT
	post_mesh.radial_segments = 10
	post_mesh.rings = 1
	post.mesh = post_mesh
	post.position.y = GAP_POST_HEIGHT * 0.5
	var ring := MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 5.5
	ring_mesh.outer_radius = 7.0
	ring_mesh.rings = 24
	ring_mesh.ring_segments = 6
	ring.mesh = ring_mesh
	ring.position.y = 0.6
	for part: MeshInstance3D in [post, ring]:
		part.material_override = material
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		marker.add_child(part)
	marker.visible = false
	return marker


func _show_gaps(points: Array) -> void:
	for n in gap_markers.size():
		var marker := gap_markers[n]
		marker.visible = n < points.size()
		if marker.visible:
			var p: Vector2 = points[n]
			marker.position = Vector3(p.x, terrain.height_at(p.x, p.y), p.y)


func _draw_preview(points: PackedFloat32Array, side: int) -> void:
	var verts := PackedVector3Array()
	verts.resize(side * side)
	var keep := PackedByteArray()
	keep.resize(side * side)
	for n in side * side:
		var o := n * 4
		verts[n] = Vector3(points[o], points[o + 1] + 0.4, points[o + 2])
		keep[n] = 1 if absf(points[o + 3]) > 0.05 else 0
	var indices := PackedInt32Array()
	for j in side - 1:
		for i in side - 1:
			var a := j * side + i
			if keep[a] + keep[a + 1] + keep[a + side] + keep[a + side + 1] == 0:
				continue
			indices.append_array(PackedInt32Array([a, a + 1, a + side, a + 1, a + side + 1, a + side]))
	var mesh := ArrayMesh.new()
	if not indices.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, ghost_material)
	ghost.mesh = mesh
	ghost.visible = not indices.is_empty()


## Places a preset. The ground rises or sinks over a moment, then routes are worked out again.
func place_preset(preset: Dictionary, at: Vector2, rotation_y: float, grow := true) -> bool:
	if not job.is_empty() or brush.locked:
		return false
	var fit := fit_preset(preset, at, rotation_y, false, grow)
	var shape: Dictionary = fit["preset"]
	at = fit["at"]
	var preview: Dictionary = terrain.preview_preset(shape, at.x, at.y, rotation_y)
	var cost := int(float(preview["volume"]) * cost_per_cubic_metre)
	if float(preview["volume"]) <= 1.0 or brush.money < float(cost):
		return false
	var patch: Dictionary = terrain.make_preset_patch(shape, at.x, at.y, rotation_y)
	var saved: PackedFloat32Array = terrain.heights.duplicate()
	brush.undo_stack.append({"heights": saved, "money": brush.money, "rect": patch["rect"]})
	brush.money -= float(cost)
	brush.ground_busy = true
	job = {
		"patch": patch, "time": 0.0, "duration": float(config["preset_rise_seconds"]),
		"at": Vector3(at.x, terrain.height_at(at.x, at.y), at.y), "radius": terrain.preset_reach(shape),
	}
	ghost.visible = false
	_show_gaps([])
	return true


func _advance_job(delta: float) -> void:
	job["time"] += delta
	var t: float = clampf(float(job["time"]) / float(job["duration"]), 0.0, 1.0)
	var eased := t * t * (3.0 - 2.0 * t)
	terrain.set_patch_progress(job["patch"], eased)
	terrain.upload_state()
	var at: Vector3 = job["at"]
	brush.sync_followers_near(Vector2(at.x, at.z), job["radius"])
	feel.shake(at, job["radius"], 1.0 - t * 0.5)
	if t >= 1.0:
		job = {}
		brush.ground_busy = false
		brush.finish_ground_change()
		last_key = PackedFloat32Array()


func _preview_tunnel(at: Vector2) -> void:
	var rules: Dictionary = config["tunnel"]
	if tunnel_start == Vector2.INF:
		var free: bool = terrain.base_edit_mask[terrain._index_of(at.x, at.y)] > 0.0 and terrain.water_mask[terrain._index_of(at.x, at.y)] == 0
		ghost.visible = false
		if free:
			_set_hint(HINT_INFO, "第一步：点山脚，选隧道的一个入口", "隧道按长度收费　·　Esc 取消")
		else:
			_set_hint(HINT_BAD, "这里不能建隧道入口", "Esc 取消")
		return
	tunnel_plan = terrain.plan_tunnel(tunnel_start, at, rules)
	var from := Vector3(tunnel_start.x, terrain.height_at(tunnel_start.x, tunnel_start.y), tunnel_start.y)
	var to := Vector3(at.x, terrain.height_at(at.x, at.y), at.y)
	var ok: bool = tunnel_plan["ok"] and brush.money >= float(tunnel_plan.get("cost", 0))
	ghost_material.albedo_color = GHOST_RAISE if ok else GHOST_BAD
	_draw_tunnel_line(from, to)
	if not tunnel_plan["ok"]:
		_set_hint(HINT_BAD, String(tunnel_plan["reason"]), "第二步：点山的另一侧　·　Esc 重选入口")
	elif not ok:
		_set_hint(HINT_BAD, "金币不够：需要 %d 金" % tunnel_plan["cost"], "Esc 重选入口")
	else:
		_set_hint(HINT_OK, "隧道长 %d 米　·　%d 金" % [int(tunnel_plan["length"]), tunnel_plan["cost"]], "左键打通　·　Esc 重选入口")


func _draw_tunnel_line(from: Vector3, to: Vector3) -> void:
	var across := (to - from).cross(Vector3.UP).normalized() * 1.6
	var lift := Vector3.UP * 1.5
	var verts := PackedVector3Array([from - across + lift, from + across + lift, to + across + lift, to - across + lift])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, ghost_material)
	ghost.mesh = mesh
	ghost.visible = true


func build_tunnel(start: Vector2, finish: Vector2) -> bool:
	var rules: Dictionary = config["tunnel"]
	var plan: Dictionary = terrain.plan_tunnel(start, finish, rules)
	if not plan["ok"] or brush.money < float(plan["cost"]) or brush.locked:
		return false
	var money_before: float = brush.money
	brush.money -= float(plan["cost"])
	var half_width: float = rules["cut_half_width"]
	var door_a: Vector2 = plan["door_a"]
	var door_b: Vector2 = plan["door_b"]
	var patch_a: Dictionary = terrain.cut_tunnel_mouth(start, door_a, plan["level_a"], half_width)
	var patch_b: Dictionary = terrain.cut_tunnel_mouth(finish, door_b, plan["level_b"], half_width)
	terrain.upload_state()
	var axis: Vector2 = plan["axis"]
	# Link points stand just outside each door, on the floor of the cutting.
	var link_a: Vector2 = door_a - axis * 1.5
	var link_b: Vector2 = door_b + axis * 1.5
	var id: int = paths.core.add_tunnel(link_a.x, link_a.y, link_b.x, link_b.y)
	var node_a := _make_portal(door_a, axis, plan["level_a"])
	var node_b := _make_portal(door_b, -axis, plan["level_b"])
	var locks: Array[Vector2] = [start, door_a, finish, door_b]
	for spot in locks:
		terrain.add_ground_lock(spot.x, spot.y)
	var tunnel := {
		"id": id, "nodes": [node_a, node_b], "doors": [door_a, door_b], "levels": [plan["level_a"], plan["level_b"]],
		"patches": [patch_a, patch_b], "locks": locks, "paid": plan["cost"], "length": plan["length"],
	}
	tunnels.append(tunnel)
	for spot: Vector2 in [door_a, door_b]:
		brush.clear_trees_near(spot.x, spot.y, 12.0)
	for spot: Vector3 in [Vector3(start.x, plan["level_a"], start.y), Vector3(finish.x, plan["level_b"], finish.y)]:
		feel.shake(spot, 10.0, 1.0)
	brush.undo_stack.append({"money": money_before, "undo": _remove_tunnel.bind(tunnel), "rect": patch_a["rect"]})
	brush.finish_ground_change()
	state_changed.emit()
	return true


func _make_portal(door: Vector2, axis_in: Vector2, level: float) -> Node3D:
	var holder := Node3D.new()
	var outward := Vector3(-axis_in.x, 0.0, -axis_in.y)
	holder.transform = Transform3D(Basis(Vector3.UP.cross(outward), Vector3.UP, outward), Vector3(door.x, level, door.y))
	add_child(holder)
	Props.build_portal(holder, rock, rng)
	_keep_off_brush_ring(holder)
	return holder


func _keep_off_brush_ring(node: Node) -> void:
	if node is VisualInstance3D:
		node.layers = Flora.LAYER_NO_DECAL
	for child in node.get_children():
		_keep_off_brush_ring(child)


func _remove_tunnel(tunnel: Dictionary) -> void:
	paths.core.remove_tunnel(tunnel["id"])
	for node: Node3D in tunnel["nodes"]:
		node.queue_free()
	for spot: Vector2 in tunnel["locks"]:
		terrain.remove_ground_lock(spot.x, spot.y)
	for patch: Dictionary in tunnel["patches"]:
		terrain.remove_tower_pad(patch)
	terrain.upload_state()
	tunnels.erase(tunnel)
	if selected_tunnel == tunnel:
		selected_tunnel = {}
	state_changed.emit()


func _tunnel_under_mouse() -> Dictionary:
	var mouse: Vector2 = brush.current_mouse()
	var origin := camera.project_ray_origin(mouse)
	var finish := origin + camera.project_ray_normal(mouse) * 900.0
	var best := {}
	var best_distance := PORTAL_PICK_DISTANCE
	for tunnel in tunnels:
		for n in 2:
			var door: Vector2 = tunnel["doors"][n]
			var base := Vector3(door.x, tunnel["levels"][n], door.y)
			var points := Geometry3D.get_closest_points_between_segments(origin, finish, base, base + Vector3.UP * 8.0)
			var distance := points[0].distance_to(points[1])
			if distance < best_distance:
				best_distance = distance
				best = tunnel
	return best


func select_tunnel(tunnel: Dictionary) -> void:
	towers.deselect()
	selected_tunnel = tunnel
	brush.ring_hidden = true
	state_changed.emit()


func deselect_tunnel() -> void:
	if selected_tunnel.is_empty():
		return
	selected_tunnel = {}
	brush.ring_hidden = false
	state_changed.emit()


func tunnel_refund() -> int:
	if selected_tunnel.is_empty():
		return 0
	return int(float(selected_tunnel["paid"]) * float(config["tunnel"]["refund"]))


## Fills in the selected tunnel and gives back part of its price.
func remove_selected_tunnel() -> void:
	if selected_tunnel.is_empty() or brush.locked:
		return
	var tunnel := selected_tunnel
	brush.money += float(tunnel_refund())
	brush.ring_hidden = false
	_remove_tunnel(tunnel)
	brush.clear_undo()
	brush.finish_ground_change()
