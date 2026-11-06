extends RefCounted
## Handcrafted-looking buildings assembled from many small irregular pieces.

const Flora = preload("res://scripts/flora.gd")

const PLASTER := Color(0.92, 0.85, 0.72)
const TIMBER := Color(0.3, 0.19, 0.13)
const STONE := Color(0.66, 0.62, 0.56)
const ROOF_RED := Color(0.56, 0.27, 0.2)
const ROOF_TEAL := Color(0.33, 0.5, 0.44)
const ROOF_SLATE := Color(0.36, 0.37, 0.42)
const WINDOW_GLOW := Color(1.0, 0.56, 0.2)

static var _materials: Dictionary = {}


static func solid(color: Color, variation := 0.12, scale := 2.0) -> ShaderMaterial:
	var key := "%s_%s_%s" % [color.to_html(), variation, scale]
	if _materials.has(key):
		return _materials[key]
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/solid.gdshader")
	material.set_shader_parameter("albedo", color)
	material.set_shader_parameter("variation", variation)
	material.set_shader_parameter("noise_scale", scale)
	_materials[key] = material
	return material


## A material for scattered items that react to sculpting (see ground_rule in solid.gdshader).
static func ground_material(terrain, color: Color, variation: float, scale: float, rule: int) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/solid.gdshader")
	material.set_shader_parameter("albedo", color)
	material.set_shader_parameter("variation", variation)
	material.set_shader_parameter("noise_scale", scale)
	material.set_shader_parameter("ground_rule", rule)
	material.set_shader_parameter("water_level", terrain.WATER_LEVEL)
	terrain.bind_state(material)
	return material


static func box(parent: Node3D, size: Vector3, pos: Vector3, material: Material, rotation := Vector3.ZERO) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = pos
	node.rotation = rotation
	parent.add_child(node)
	return node


## Rounded noisy rock, shared by walls, chimneys and scattered stones.
static func make_rock_mesh(seed_value: int) -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radial_segments = 8
	sphere.rings = 5
	sphere.radius = 1.0
	sphere.height = 2.0
	var arrays := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 1.1
	for i in verts.size():
		var d := verts[i].normalized()
		verts[i] = d * (1.0 + noise.get_noise_3dv(d) * 0.55)
		norms[i] = d
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func add_instances(parent: Node3D, mesh: Mesh, material: Material, items: Array[Dictionary]) -> MultiMeshInstance3D:
	var instance_mesh: Mesh = mesh.duplicate()
	instance_mesh.surface_set_material(0, material)
	var buffer := PackedFloat32Array()
	buffer.resize(items.size() * 20)
	for i in items.size():
		var item: Dictionary = items[i]
		Flora._write_instance(buffer, i * 20, item["basis"], item["pos"], item.get("color", Color.WHITE), item.get("custom", Vector3.UP))
	var node := MultiMeshInstance3D.new()
	node.multimesh = Flora._make_multimesh(instance_mesh, buffer, items.size())
	parent.add_child(node)
	return node


## Shingled gable roof centered on the origin with its ridge along X.
static func gable_roof(parent: Node3D, pos: Vector3, length: float, span: float, rise: float, color: Color, rng: RandomNumberGenerator) -> void:
	var holder := Node3D.new()
	holder.position = pos
	parent.add_child(holder)
	var slope_len := Vector2(span * 0.5 + 0.55, rise * (span * 0.5 + 0.55) / (span * 0.5)).length()
	var angle := atan2(rise, span * 0.5)
	var shingle := BoxMesh.new()
	shingle.size = Vector3(1.0, 1.0, 1.0)
	var items: Array[Dictionary] = []
	var row_step := 0.44
	var col_step := 0.56
	var rows := int(slope_len / row_step)
	var cols := int((length + 1.1) / col_step)
	for side_index in 2:
		var side := 1.0 if side_index == 0 else -1.0
		for r in rows:
			var offset := (0.5 if r % 2 == 1 else 0.0) * col_step
			var t := (float(r) + 0.5) * row_step
			var outward := t * cos(angle) * side
			var height := rise - t * sin(angle)
			for c in cols:
				var x := -length * 0.5 - 0.55 + (float(c) + 0.5) * col_step + offset
				if x > length * 0.5 + 0.55:
					continue
				var tilt := Basis(Vector3.RIGHT, side * (angle + 0.08) + rng.randf_range(-0.05, 0.05))
				var basis := tilt * Basis(Vector3.UP, rng.randf_range(-0.05, 0.05))
				basis = basis.scaled_local(Vector3(col_step * rng.randf_range(0.92, 1.0), 0.09, row_step * 1.65))
				var v := rng.randf_range(0.72, 1.18)
				items.append({
					"basis": basis,
					"pos": Vector3(x, height + 0.06, outward),
					"color": Color(v, v, v),
				})
	add_instances(holder, shingle, solid(color, 0.1, 5.0), items)
	var cap := BoxMesh.new()
	cap.size = Vector3(length + 1.2, 0.2, 0.34)
	cap.material = solid(color.darkened(0.25), 0.1)
	var ridge := MeshInstance3D.new()
	ridge.mesh = cap
	ridge.position = Vector3(0.0, rise + 0.1, 0.0)
	holder.add_child(ridge)
	# Plaster gable ends, with a dark underlayer below the shingles.
	var h_l := length * 0.5
	var s_h := span * 0.5
	_add_triangles(holder, solid(PLASTER, 0.1, 1.2), [
		Vector3(-h_l, 0.0, s_h), Vector3(-h_l, 0.0, -s_h), Vector3(-h_l, rise, 0.0),
		Vector3(h_l, 0.0, -s_h), Vector3(h_l, 0.0, s_h), Vector3(h_l, rise, 0.0),
	])
	_add_triangles(holder, solid(color.darkened(0.55), 0.05), [
		Vector3(-h_l, 0.0, s_h), Vector3(-h_l, rise, 0.0), Vector3(h_l, rise, 0.0),
		Vector3(-h_l, 0.0, s_h), Vector3(h_l, rise, 0.0), Vector3(h_l, 0.0, s_h),
		Vector3(h_l, 0.0, -s_h), Vector3(h_l, rise, 0.0), Vector3(-h_l, rise, 0.0),
		Vector3(h_l, 0.0, -s_h), Vector3(-h_l, rise, 0.0), Vector3(-h_l, 0.0, -s_h),
	])


static func _add_triangles(parent: Node3D, material: Material, points: Array[Vector3]) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in points:
		st.add_vertex(p)
	st.generate_normals()
	var node := MeshInstance3D.new()
	node.mesh = st.commit()
	node.material_override = material
	parent.add_child(node)


static func glowing_window(parent: Node3D, pos: Vector3, size: Vector2, facing_z: bool, glow: Array[ShaderMaterial]) -> void:
	var dims := Vector3(size.x, size.y, 0.12) if facing_z else Vector3(0.12, size.y, size.x)
	var material := solid(Color(0.1, 0.09, 0.1), 0.0)
	box(parent, dims, pos, material)
	var frame := solid(TIMBER)
	if facing_z:
		box(parent, Vector3(size.x + 0.26, 0.13, 0.2), pos + Vector3(0.0, size.y * 0.5 + 0.05, 0.03), frame)
		box(parent, Vector3(size.x + 0.26, 0.17, 0.3), pos - Vector3(0.0, size.y * 0.5 + 0.05, -0.05), frame)
		box(parent, Vector3(0.09, size.y, 0.18), pos + Vector3(0.0, 0.0, 0.04), frame)
		box(parent, Vector3(size.x, 0.08, 0.18), pos + Vector3(0.0, 0.0, 0.04), frame)
	else:
		box(parent, Vector3(0.2, 0.13, size.x + 0.26), pos + Vector3(0.03, size.y * 0.5 + 0.05, 0.0), frame)
		box(parent, Vector3(0.3, 0.17, size.x + 0.26), pos - Vector3(-0.05, size.y * 0.5 + 0.05, 0.0), frame)
		box(parent, Vector3(0.18, size.y, 0.09), pos + Vector3(0.04, 0.0, 0.0), frame)
		box(parent, Vector3(0.18, 0.08, size.x), pos + Vector3(0.04, 0.0, 0.0), frame)


static func stone_course(parent: Node3D, rock: Mesh, material: Material, start: Vector3, finish: Vector3, height: float, stone_size: float, rng: RandomNumberGenerator, openings: Array[Vector2] = []) -> void:
	var items: Array[Dictionary] = []
	var length := start.distance_to(finish)
	var dir := (finish - start).normalized()
	var layers := int(height / (stone_size * 0.75))
	for layer in layers:
		var count := int(length / (stone_size * 1.25))
		for n in count:
			var t := (float(n) + (0.5 if layer % 2 == 1 else 0.0)) / float(maxi(count, 1))
			# Openings hold (center along the wall, half width) for doors and windows.
			var along := t * length
			var blocked := false
			for opening in openings:
				if absf(along - opening.x) < opening.y:
					blocked = true
					break
			if blocked:
				continue
			var s := stone_size * rng.randf_range(0.62, 0.86)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * 0.68, s * rng.randf_range(0.8, 1.05)))
			var v := rng.randf_range(0.8, 1.14)
			items.append({
				"basis": basis,
				"pos": start + dir * t * length + Vector3.UP * (float(layer) * stone_size * 0.7 + stone_size * 0.3),
				"color": Color(v, v * 0.98, v * 0.95),
			})
	add_instances(parent, rock, material, items)


static func lantern(world: Node3D, world_pos: Vector3, lights: Array[OmniLight3D], range_value := 11.0) -> Node3D:
	# Everything hangs off one node, so the post can follow the ground as a unit.
	var parent := Node3D.new()
	parent.position = world_pos
	world.add_child(parent)
	var pos := Vector3.ZERO
	box(parent, Vector3(0.2, 2.8, 0.2), pos + Vector3(0.0, 1.4, 0.0), solid(TIMBER))
	box(parent, Vector3(0.7, 0.1, 0.1), pos + Vector3(0.3, 2.75, 0.0), solid(TIMBER))
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/solid.gdshader")
	material.set_shader_parameter("albedo", Color(0.2, 0.15, 0.1))
	box(parent, Vector3(0.28, 0.4, 0.28), pos + Vector3(0.58, 2.48, 0.0), material)
	box(parent, Vector3(0.38, 0.08, 0.38), pos + Vector3(0.58, 2.72, 0.0), solid(TIMBER))
	return parent


static func build_house(parent: Node3D, pos: Vector3, yaw: float, roof_color: Color, rng: RandomNumberGenerator, rock: Mesh, glow: Array[ShaderMaterial]) -> void:
	var house := Node3D.new()
	house.position = pos
	house.rotation.y = yaw
	house.scale = Vector3.ONE * 1.35
	parent.add_child(house)
	var plaster := solid(PLASTER, 0.12, 1.5)
	var timber := solid(TIMBER, 0.28, 4.0)
	var stone := solid(STONE, 0.16, 2.0)
	var w := 8.6
	var d := 6.0
	# Stone base.
	box(house, Vector3(w, 2.2, d), Vector3(0.0, 0.8, 0.0), stone)
	var front_gaps: Array[Vector2] = [
		Vector2(w * 0.5, 1.05),
		Vector2(w * 0.5 - w * 0.33, 0.8),
		Vector2(w * 0.5 + w * 0.33, 0.8),
	]
	stone_course(house, rock, stone, Vector3(-w * 0.5, 0.0, d * 0.5), Vector3(w * 0.5, 0.0, d * 0.5), 1.9, 0.62, rng, front_gaps)
	stone_course(house, rock, stone, Vector3(-w * 0.5, 0.0, -d * 0.5), Vector3(w * 0.5, 0.0, -d * 0.5), 1.9, 0.62, rng)
	for x_side: float in [w * 0.5, -w * 0.5]:
		stone_course(house, rock, stone, Vector3(x_side, 0.0, -d * 0.5), Vector3(x_side, 0.0, d * 0.5), 1.9, 0.62, rng)
	# Plaster upper floor with timber framing.
	box(house, Vector3(w + 0.4, 2.7, d + 0.4), Vector3(0.0, 3.3, 0.0), plaster)
	var front := d * 0.5 + 0.22
	for side: float in [front, -front]:
		box(house, Vector3(w + 0.6, 0.28, 0.22), Vector3(0.0, 2.05, side), timber)
		box(house, Vector3(w + 0.6, 0.26, 0.22), Vector3(0.0, 4.6, side), timber)
		for n in 5:
			var x := -w * 0.5 + float(n) * w * 0.25
			box(house, Vector3(0.23, 2.4, 0.2), Vector3(x, 3.3, side), timber)
		box(house, Vector3(0.18, 2.9, 0.16), Vector3(-w * 0.375, 3.3, side), timber, Vector3(0.0, 0.0, 0.62))
		box(house, Vector3(0.18, 2.9, 0.16), Vector3(w * 0.375, 3.3, side), timber, Vector3(0.0, 0.0, -0.62))
	var gable := w * 0.5 + 0.22
	for side: float in [gable, -gable]:
		box(house, Vector3(0.22, 0.28, d + 0.6), Vector3(side, 2.05, 0.0), timber)
		box(house, Vector3(0.22, 0.26, d + 0.6), Vector3(side, 4.6, 0.0), timber)
		for n in 3:
			box(house, Vector3(0.2, 2.4, 0.22), Vector3(side, 3.3, -d * 0.5 + float(n) * d * 0.5), timber)
	# Windows, door and step.
	for wx: float in [-w * 0.125, w * 0.125]:
		glowing_window(house, Vector3(wx, 3.35, front + 0.02), Vector2(0.95, 1.2), true, glow)
	for wx: float in [-w * 0.33, w * 0.33]:
		glowing_window(house, Vector3(wx, 1.3, d * 0.5 + 0.3), Vector2(0.9, 1.05), true, glow)
	glowing_window(house, Vector3(gable + 0.02, 3.35, 0.0), Vector2(1.0, 1.2), false, glow)
	box(house, Vector3(1.4, 2.1, 0.2), Vector3(0.0, 1.05, d * 0.5 + 0.34), solid(Color(0.36, 0.22, 0.14), 0.3, 5.0))
	box(house, Vector3(1.8, 0.22, 0.28), Vector3(0.0, 2.2, d * 0.5 + 0.36), timber)
	box(house, Vector3(2.4, 0.3, 1.2), Vector3(0.0, 0.1, d * 0.5 + 0.9), stone)
	# Roof, front dormer and porch.
	gable_roof(house, Vector3(0.0, 4.72, 0.0), w + 0.6, d + 0.6, 3.5, roof_color, rng)
	var dormer := Node3D.new()
	dormer.position = Vector3(-w * 0.2, 5.55, d * 0.24)
	dormer.rotation.y = -PI * 0.5
	house.add_child(dormer)
	box(dormer, Vector3(2.0, 1.5, 1.9), Vector3(0.0, 0.5, 0.0), plaster)
	gable_roof(dormer, Vector3(0.0, 1.18, 0.0), 2.3, 2.1, 0.95, roof_color, rng)
	glowing_window(dormer, Vector3(1.03, 0.6, 0.0), Vector2(0.7, 0.8), false, glow)
	# Chimney built from rock courses.
	var chimney := Vector3(w * 0.27, 5.2, -0.9)
	box(house, Vector3(1.0, 4.6, 1.0), chimney + Vector3(0.0, 1.6, 0.0), stone)
	stone_course(house, rock, stone, chimney + Vector3(-0.55, -0.4, 0.52), chimney + Vector3(0.55, -0.4, 0.52), 4.2, 0.36, rng)
	stone_course(house, rock, stone, chimney + Vector3(0.53, -0.4, -0.55), chimney + Vector3(0.53, -0.4, 0.55), 4.2, 0.36, rng)
	box(house, Vector3(1.25, 0.2, 1.25), chimney + Vector3(0.0, 3.95, 0.0), stone)
	add_smoke(house, chimney + Vector3(0.0, 4.2, 0.0))


static func add_smoke(parent: Node3D, pos: Vector3) -> void:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	material.vertex_color_use_as_albedo = true
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
	gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	gradient.add_point(0.15, Color(0.95, 0.93, 0.92, 0.42))
	gradient.add_point(0.7, Color(0.9, 0.88, 0.9, 0.12))
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	var dot := Gradient.new()
	dot.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	dot.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var dot_texture := GradientTexture2D.new()
	dot_texture.gradient = dot
	dot_texture.fill = GradientTexture2D.FILL_RADIAL
	dot_texture.fill_from = Vector2(0.5, 0.5)
	dot_texture.fill_to = Vector2(1.0, 0.5)
	material.albedo_texture = dot_texture
	var mesh := QuadMesh.new()
	mesh.size = Vector2(1.0, 1.0)
	mesh.material = material
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0.2, 1.0, 0.1)
	process.spread = 8.0
	process.initial_velocity_min = 0.9
	process.initial_velocity_max = 1.3
	process.gravity = Vector3(0.14, 0.05, 0.05)
	process.scale_min = 0.6
	process.scale_max = 1.0
	var scale_curve := CurveTexture.new()
	var curve := Curve.new()
	curve.max_value = 5.0
	curve.add_point(Vector2(0.0, 0.7))
	curve.add_point(Vector2(1.0, 4.5))
	scale_curve.curve = curve
	process.scale_curve = scale_curve
	process.color_ramp = ramp
	var smoke := GPUParticles3D.new()
	smoke.amount = 40
	smoke.lifetime = 9.0
	smoke.preprocess = 9.0
	smoke.position = pos
	smoke.draw_pass_1 = mesh
	smoke.process_material = process
	smoke.visibility_aabb = AABB(Vector3(-15.0, -3.0, -15.0), Vector3(30.0, 30.0, 30.0))
	smoke.layers = Flora.LAYER_MAIN_ONLY
	smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(smoke)


## A tunnel mouth, facing +Z: a dark opening framed by stone and timber.
static func build_portal(parent: Node3D, rock: Mesh, rng: RandomNumberGenerator) -> void:
	var stone := solid(STONE, 0.18, 2.0)
	var wood := solid(TIMBER, 0.28, 4.0)
	var dark := StandardMaterial3D.new()
	dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dark.albedo_color = Color(0.015, 0.012, 0.012)
	box(parent, Vector3(8.0, 7.2, 0.6), Vector3(0.0, 3.0, -0.5), dark)
	# A wall of stone behind the frame closes any gap between the arch and the cut hillside.
	box(parent, Vector3(15.0, 13.0, 1.2), Vector3(0.0, 6.0, -1.4), stone)
	var items: Array[Dictionary] = []
	for side: float in [-1.0, 1.0]:
		for layer in 7:
			var s := rng.randf_range(0.82, 1.05)
			var v := rng.randf_range(0.82, 1.12)
			items.append({
				"basis": Basis(Vector3.UP, rng.randf() * TAU).scaled_local(Vector3(s, s * 0.72, s)),
				"pos": Vector3(side * 4.7, 0.3 + float(layer) * 1.05, 0.1),
				"color": Color(v, v, v * 0.96),
			})
	for n in 11:
		var a := PI * float(n) / 10.0
		var s := rng.randf_range(0.8, 1.0)
		var v := rng.randf_range(0.82, 1.12)
		items.append({
			"basis": Basis(Vector3.BACK, a).scaled_local(Vector3(s, s * 0.8, s)),
			"pos": Vector3(cos(a) * 4.7, 7.2 + sin(a) * 2.6, 0.1),
			"color": Color(v, v, v * 0.96),
		})
	add_instances(parent, rock, stone, items)
	for side: float in [-1.0, 1.0]:
		box(parent, Vector3(0.5, 6.8, 0.5), Vector3(side * 3.9, 3.2, 0.4), wood)
	box(parent, Vector3(8.6, 0.55, 0.6), Vector3(0.0, 6.5, 0.45), wood)


static func build_wall(parent: Node3D, terrain, rock: Mesh, points: Array[Vector2], rng: RandomNumberGenerator) -> void:
	var stone := solid(STONE, 0.16, 2.0)
	var items: Array[Dictionary] = []
	for p in points.size() - 1:
		var a := points[p]
		var b := points[p + 1]
		var length := a.distance_to(b)
		var count := int(length / 0.8)
		for n in count:
			var t := float(n) / float(count)
			var q := a.lerp(b, t)
			var ground: float = terrain.height_at(q.x, q.y)
			for layer in 3:
				var s := rng.randf_range(0.5, 0.78) * (1.0 - float(layer) * 0.08)
				var v := rng.randf_range(0.8, 1.14)
				items.append({
					"basis": Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * 0.66, s * 0.85)),
					"pos": Vector3(q.x + rng.randf_range(-0.1, 0.1), ground + 0.25 + float(layer) * 0.56, q.y + rng.randf_range(-0.1, 0.1)),
					"color": Color(v, v, v * 0.95),
				})
	add_instances(parent, rock, stone, items)


## Boulders around the pit, on steep faces and along the shore.
static func scatter_rocks(parent: Node3D, terrain, rock: Mesh, rng: RandomNumberGenerator) -> void:
	var rock_material := ground_material(terrain, Color(0.61, 0.57, 0.52), 0.2, 1.1, 1)
	var items: Array[Dictionary] = []
	for patch: Vector3 in terrain.shape.rock_patches():
		for n in 300:
			var a := rng.randf() * TAU
			var d: float = sqrt(rng.randf()) * patch.z
			var x: float = patch.x + cos(a) * d
			var z: float = patch.y + sin(a) * d
			var s := pow(rng.randf(), 1.8) * 1.5 + 0.34
			items.append(_rock_item(x, terrain.height_at(x, z) + s * 0.2, z, s, rng))
	var half: float = terrain.SIZE * 0.5
	var placed := 0
	var attempts := 0
	while placed < 460 and attempts < 40000:
		attempts += 1
		var x := rng.randf_range(-half, half)
		var z := rng.randf_range(-half, half)
		var ny: float = terrain.normal_at(x, z).y
		var h: float = terrain.height_at(x, z)
		var near_shore: bool = h > terrain.WATER_LEVEL - 0.4 and h < terrain.WATER_LEVEL + 0.8
		var steep := ny < 0.82
		if not steep and not near_shore:
			continue
		if near_shore and rng.randf() > 0.2:
			continue
		var s := pow(rng.randf(), 2.2) * 2.3 + 0.35
		items.append(_rock_item(x, h + s * 0.1, z, s, rng))
		placed += 1
	for item in items:
		var pos: Vector3 = item["pos"]
		item["custom"] = Vector3(terrain.height_at(pos.x, pos.z), 0.0, 0.0)
	var node := add_instances(parent, rock, rock_material, items)
	node.custom_aabb = AABB(Vector3(-half, -60.0, -half), Vector3(terrain.SIZE, 260.0, terrain.SIZE))


static func _rock_item(x: float, y: float, z: float, s: float, rng: RandomNumberGenerator) -> Dictionary:
	var v := rng.randf_range(0.82, 1.14)
	return {
		"basis": Basis(Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized(), rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.6, 0.9), s * rng.randf_range(0.8, 1.1))),
		"pos": Vector3(x, y, z),
		"color": Color(v, v, v * 0.96),
	}


## Lily pads and reeds in the lake shallows.
static func build_water_plants(parent: Node3D, terrain, rng: RandomNumberGenerator) -> void:
	var half: float = terrain.SIZE * 0.5
	var pad := CylinderMesh.new()
	pad.top_radius = 1.0
	pad.bottom_radius = 1.0
	pad.height = 0.04
	pad.radial_segments = 10
	pad.rings = 1
	var reed := BoxMesh.new()
	var pads: Array[Dictionary] = []
	var reeds: Array[Dictionary] = []
	var attempts := 0
	while attempts < 90000 and (pads.size() < 260 or reeds.size() < 650):
		attempts += 1
		var x := rng.randf_range(-half, half)
		var z := rng.randf_range(-half, half)
		if terrain.water_mask[terrain._index_of(x, z)] == 0:
			continue
		var depth: float = terrain.WATER_LEVEL - terrain.height_at(x, z)
		if depth < 2.0 and pads.size() < 260 and rng.randf() < 0.3:
			var s := rng.randf_range(0.38, 0.95)
			var v := rng.randf_range(0.8, 1.15)
			pads.append({
				"basis": Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, 1.0, s)),
				"pos": Vector3(x, terrain.WATER_LEVEL + 0.04, z),
				"color": Color(v, v, v),
			})
		elif depth < 0.75 and reeds.size() < 650:
			var h := rng.randf_range(1.2, 2.3)
			var v := rng.randf_range(0.82, 1.16)
			var lean := Basis(Vector3(rng.randfn(), 0.0, rng.randfn()).normalized(), rng.randf_range(-0.12, 0.12))
			reeds.append({
				"basis": lean.scaled(Vector3(0.07, h, 0.07)),
				"pos": Vector3(x, terrain.WATER_LEVEL + h * 0.4, z),
				"color": Color(v, v, v * 0.9),
			})
	var pad_material := ground_material(terrain, Color(0.36, 0.56, 0.32), 0.1, 2.0, 3)
	var pad_node := add_instances(parent, pad, pad_material, pads)
	pad_node.layers = Flora.LAYER_MAIN_ONLY
	add_instances(parent, reed, ground_material(terrain, Color(0.58, 0.62, 0.32), 0.1, 2.0, 3), reeds)


## Spikes of purple and white flowers around the house.
static func build_flowers(parent: Node3D, terrain, center: Vector2, rng: RandomNumberGenerator) -> void:
	var flower := SphereMesh.new()
	flower.radial_segments = 5
	flower.rings = 3
	flower.radius = 1.0
	flower.height = 2.0
	var stem := BoxMesh.new()
	var buds: Array[Dictionary] = []
	var stems: Array[Dictionary] = []
	var tints: Array[Color] = [Color(0.56, 0.42, 0.86), Color(0.72, 0.56, 0.92), Color(1.0, 0.92, 0.94), Color(0.96, 0.6, 0.74)]
	for clump in 34:
		var a := rng.randf() * TAU
		var d := rng.randf_range(8.0, 21.0)
		var cx := center.x + cos(a) * d
		var cz := center.y + sin(a) * d
		var tint: Color = tints[rng.randi_range(0, tints.size() - 1)].srgb_to_linear()
		for n in rng.randi_range(9, 18):
			var x := cx + rng.randfn() * 0.9
			var z := cz + rng.randfn() * 0.9
			if terrain.path_at(x, z) > 0.2:
				continue
			var y: float = terrain.height_at(x, z)
			var h := rng.randf_range(0.9, 1.5)
			stems.append({
				"basis": Basis().scaled(Vector3(0.05, h, 0.05)),
				"pos": Vector3(x, y + h * 0.5, z),
			})
			for b in 8:
				var t := float(b) / 7.0
				var s := lerpf(0.12, 0.05, t)
				buds.append({
					"basis": Basis().scaled(Vector3(s, s, s)),
					"pos": Vector3(x + rng.randf_range(-0.05, 0.05), y + h * lerpf(0.45, 1.02, t), z + rng.randf_range(-0.05, 0.05)),
					"color": tint,
				})
	var bud_material := solid(Color.WHITE, 0.0)
	add_instances(parent, flower, bud_material, buds)
	add_instances(parent, stem, solid(Color(0.3, 0.46, 0.24), 0.05), stems)


static func build_village(parent: Node3D, terrain, rng: RandomNumberGenerator) -> Dictionary:
	var glow: Array[ShaderMaterial] = []
	var lights: Array[OmniLight3D] = []
	var rock := make_rock_mesh(7)
	var home: Vector2 = terrain.home_center()
	var layout: Array[Array] = [
		[Vector2(-2.0, 10.0), 0.2, ROOF_RED],
		[Vector2(-20.0, -4.0), 0.85, ROOF_TEAL],
		[Vector2(19.0, 1.0), -0.7, ROOF_RED],
	]
	for item in layout:
		var offset: Vector2 = item[0]
		var x := home.x + offset.x
		var z := home.y + offset.y
		build_house(parent, Vector3(x, terrain.height_at(x, z) + 0.15, z), item[1], item[2], rng, rock, glow)
	# Low fieldstone wall with a gap for the path, broken up by lantern posts.
	var wall_a: Array[Vector2] = []
	var wall_b: Array[Vector2] = []
	for n in 14:
		var a := PI + PI * 0.47 - float(n) * PI * 0.038
		wall_a.append(home + Vector2(cos(a) * 28.0, -absf(sin(a)) * 16.0 - 3.0))
		var b := PI * 1.53 + float(n) * PI * 0.038
		wall_b.append(home + Vector2(cos(b) * 28.0, -absf(sin(b)) * 16.0 - 3.0))
	build_wall(parent, terrain, rock, wall_a, rng)
	build_wall(parent, terrain, rock, wall_b, rng)
	var lanterns: Array[Node3D] = []
	var spots: Array[Vector2] = [wall_a[0] + Vector2(-2.3, -1.0), wall_b[0] + Vector2(2.3, -1.0), home + Vector2(-5.0, 3.0), home + Vector2(7.0, 3.5)]
	spots.append_array(terrain.shape.lantern_spots())
	for q in spots:
		lanterns.append(lantern(parent, Vector3(q.x, terrain.height_at(q.x, q.y), q.y), lights, 15.0))
	scatter_rocks(parent, terrain, rock, rng)
	build_water_plants(parent, terrain, rng)
	build_flowers(parent, terrain, home, rng)
	return {"lanterns": lanterns}
