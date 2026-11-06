extends RefCounted
## Grass, sakura trees and petals. Everything is instanced for speed.

## Kept so the tower range display can tint the grass.
static var grass_material: ShaderMaterial

const LAYER_MAIN_ONLY := 2
## Trees and towers use this layer, so the brush ring only appears on the ground.
const LAYER_NO_DECAL := 4
const GRASS_CHUNK := 20.0
const NEAR_DENSITY := 4.0
const FAR_DENSITY := 1.8
const NEAR_RANGE := 90.0
## Beyond this distance a tree switches to a third of its leaves, each one larger.
const LEAF_LOD_RANGE := 120.0
const PETAL_MAP_SIZE := 160

const PINK_PALETTE := {
	"top": Color(0.97, 0.72, 0.8), "mid": Color(0.93, 0.6, 0.72), "low": Color(0.78, 0.44, 0.6),
	"core": Color(0.6, 0.34, 0.48),
}
const PALE_PALETTE := {
	"top": Color(0.97, 0.8, 0.84), "mid": Color(0.94, 0.68, 0.76), "low": Color(0.8, 0.52, 0.63),
	"core": Color(0.64, 0.42, 0.52),
}
const GREEN_PALETTE := {
	"top": Color(0.66, 0.76, 0.48), "mid": Color(0.5, 0.65, 0.42), "low": Color(0.38, 0.54, 0.38),
	"core": Color(0.3, 0.44, 0.32),
}
const GOLD_PALETTE := {
	"top": Color(0.96, 0.86, 0.56), "mid": Color(0.85, 0.72, 0.42), "low": Color(0.62, 0.56, 0.34),
	"core": Color(0.42, 0.38, 0.24),
}


static func _to_linear(c: Color) -> Color:
	return c.srgb_to_linear()


static func _shader_material(path: String) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(path)
	return material


## A tuft of curved tapered blades. UV.y runs from root to tip.
static func make_tuft_mesh(rng: RandomNumberGenerator, blades: int, segments: int, width: float, height: float, spread: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for b in blades:
		var base := Vector3(rng.randf_range(-spread, spread), 0.0, rng.randf_range(-spread, spread))
		var yaw := rng.randf() * TAU
		var side := Vector3(cos(yaw), 0.0, sin(yaw))
		var lean := Vector3(-side.z, 0.0, side.x) * rng.randf_range(0.1, 0.45)
		var blade_h := height * rng.randf_range(0.7, 1.15)
		var first := verts.size()
		for s in segments + 1:
			var t := float(s) / float(segments)
			var w := width * (1.0 - t * t) * 0.5 + 0.004
			var center := base + Vector3.UP * blade_h * t + lean * blade_h * t * t
			verts.append(center - side * w)
			verts.append(center + side * w)
			norms.append(Vector3.UP)
			norms.append(Vector3.UP)
			uvs.append(Vector2(0.0, t))
			uvs.append(Vector2(1.0, t))
			colors.append(Color.WHITE)
			colors.append(Color.WHITE)
		for s in segments:
			var a := first + s * 2
			indices.append_array(PackedInt32Array([a, a + 1, a + 2, a + 1, a + 3, a + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _grass_allowed(terrain, x: float, z: float) -> bool:
	var h: float = terrain.height_at(x, z)
	if h < terrain.WATER_LEVEL + 0.5:
		return false
	if terrain.normal_at(x, z).y < 0.64:
		return false
	if terrain.dig_at(x, z) > 0.28:
		return false
	return terrain.path_at(x, z) < 0.42


static func _write_instance(buffer: PackedFloat32Array, o: int, basis: Basis, pos: Vector3, color: Color, custom: Vector3, custom_w := 0.0) -> void:
	buffer[o] = basis.x.x
	buffer[o + 1] = basis.y.x
	buffer[o + 2] = basis.z.x
	buffer[o + 3] = pos.x
	buffer[o + 4] = basis.x.y
	buffer[o + 5] = basis.y.y
	buffer[o + 6] = basis.z.y
	buffer[o + 7] = pos.y
	buffer[o + 8] = basis.x.z
	buffer[o + 9] = basis.y.z
	buffer[o + 10] = basis.z.z
	buffer[o + 11] = pos.z
	buffer[o + 12] = color.r
	buffer[o + 13] = color.g
	buffer[o + 14] = color.b
	buffer[o + 15] = 1.0
	buffer[o + 16] = custom.x
	buffer[o + 17] = custom.y
	buffer[o + 18] = custom.z
	buffer[o + 19] = custom_w


static func _make_multimesh(mesh: Mesh, buffer: PackedFloat32Array, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	if count > 0:
		buffer.resize(count * 20)
		mm.buffer = buffer
	return mm


## Coarse map of where petals gather: drifts under trees plus loose meadow patches.
static func make_petal_map(terrain, trees: Array[Vector3]) -> PackedFloat32Array:
	var size := PETAL_MAP_SIZE
	var cell: float = terrain.SIZE / float(size)
	var half: float = terrain.SIZE * 0.5
	var map := PackedFloat32Array()
	map.resize(size * size)
	var noise := FastNoiseLite.new()
	noise.seed = 88
	noise.frequency = 0.04
	noise.fractal_octaves = 3
	for j in size:
		for i in size:
			var n := noise.get_noise_2d(-half + float(i) * cell, -half + float(j) * cell)
			map[j * size + i] = smoothstep(0.08, 0.42, n) * 0.6
	for tree in trees:
		var radius := 15.0
		var ci := int((tree.x + half) / cell)
		var cj := int((tree.z + half) / cell)
		var reach := int(radius / cell) + 1
		for j in range(maxi(cj - reach, 0), mini(cj + reach + 1, size)):
			for i in range(maxi(ci - reach, 0), mini(ci + reach + 1, size)):
				var dx := -half + float(i) * cell - tree.x
				var dz := -half + float(j) * cell - tree.z
				var value := 1.0 - smoothstep(4.0, radius, sqrt(dx * dx + dz * dz))
				map[j * size + i] = maxf(map[j * size + i], value * 0.85)
	return map


static func _petal_amount(terrain, map: PackedFloat32Array, x: float, z: float) -> float:
	var size := PETAL_MAP_SIZE
	var half: float = terrain.SIZE * 0.5
	var i := clampi(int((x + half) / terrain.SIZE * float(size)), 0, size - 1)
	var j := clampi(int((z + half) / terrain.SIZE * float(size)), 0, size - 1)
	return map[j * size + i]


static func build_grass(parent: Node3D, terrain, rng: RandomNumberGenerator, petal_map: PackedFloat32Array, meadow_map: Texture2D) -> int:
	var material := _shader_material("res://shaders/grass.gdshader")
	grass_material = material
	terrain.bind_state(material)
	material.set_shader_parameter("water_level", terrain.WATER_LEVEL)
	material.set_shader_parameter("meadow_map", meadow_map)
	material.set_shader_parameter("meadow_size", terrain.SIZE)
	var near_mesh := make_tuft_mesh(rng, 6, 2, 0.12, 0.72, 0.38)
	var far_mesh := make_tuft_mesh(rng, 4, 1, 0.55, 0.85, 0.6)
	near_mesh.surface_set_material(0, material)
	far_mesh.surface_set_material(0, material)
	var half: float = terrain.SIZE * 0.5
	var chunks := int(terrain.SIZE / GRASS_CHUNK)
	var total := 0
	for cj in chunks:
		for ci in chunks:
			var origin := Vector2(-half + float(ci) * GRASS_CHUNK, -half + float(cj) * GRASS_CHUNK)
			total += _build_grass_chunk(parent, terrain, rng, petal_map, origin, near_mesh, NEAR_DENSITY, true)
			total += _build_grass_chunk(parent, terrain, rng, petal_map, origin, far_mesh, FAR_DENSITY, false)
	return total


static func _build_grass_chunk(parent: Node3D, terrain, rng: RandomNumberGenerator, petal_map: PackedFloat32Array, origin: Vector2, mesh: Mesh, density: float, near: bool) -> int:
	var attempts := int(GRASS_CHUNK * GRASS_CHUNK * density)
	var buffer := PackedFloat32Array()
	buffer.resize(attempts * 20)
	var count := 0
	var low := INF
	var high := -INF
	for n in attempts:
		var x := origin.x + rng.randf() * GRASS_CHUNK
		var z := origin.y + rng.randf() * GRASS_CHUNK
		var ground: float = terrain.height_at(x, z)
		low = minf(low, ground)
		high = maxf(high, ground)
		# Height and visibility come from the live terrain in the shader.
		var pos := Vector3(x, 0.0, z)
		var scale := rng.randf_range(0.75, 1.3)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(scale, scale * rng.randf_range(0.85, 1.25), scale))
		var v := rng.randf_range(0.86, 1.14)
		var amount := _petal_amount(terrain, petal_map, x, z)
		var pink := amount * 0.62 if rng.randf() < amount * 0.4 else 0.0
		var path: float = terrain.path_at(x, z)
		_write_instance(buffer, count * 20, basis, pos, Color(v, v * rng.randf_range(0.96, 1.04), v * 0.94), Vector3(path, 0.0, 0.0), pink)
		count += 1
	if count == 0:
		return 0
	var node := MultiMeshInstance3D.new()
	node.multimesh = _make_multimesh(mesh, buffer, count)
	# Sculpting can move this chunk's grass well above or below where it started.
	node.custom_aabb = AABB(Vector3(origin.x, low - 45.0, origin.y), Vector3(GRASS_CHUNK, high - low + 95.0, GRASS_CHUNK))
	node.layers = LAYER_MAIN_ONLY
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	if near:
		node.visibility_range_end = NEAR_RANGE
		node.visibility_range_end_margin = 15.0
	else:
		node.visibility_range_begin = NEAR_RANGE
		node.visibility_range_begin_margin = 15.0
	node.add_to_group("grass")
	parent.add_child(node)
	return count


## Flat, slightly folded leaf with a pointed tip.
static func make_leaf_mesh(size := 1.0) -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(0.0, -0.62, 0.0) * size, Vector3(0.36, -0.28, 0.04) * size, Vector3(0.42, 0.16, 0.05) * size,
		Vector3(0.0, 0.62, 0.0) * size, Vector3(-0.42, 0.16, 0.05) * size, Vector3(-0.36, -0.28, 0.04) * size,
	])
	var norms := PackedVector3Array()
	norms.resize(6)
	norms.fill(Vector3.BACK)
	var colors := PackedColorArray()
	colors.resize(6)
	colors.fill(Color.WHITE)
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Pointed leaf with its tip along +Y. The base is darker and the two halves differ a little,
## so overlapping leaves read as layers. Vertex colors stop at 1, so the shader multiplies by 1.25.
static func make_canopy_leaf_mesh(detailed: bool) -> ArrayMesh:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	if detailed:
		for half: float in [-1.0, 1.0]:
			var first := verts.size()
			var tone := 1.0 if half < 0.0 else 0.9
			verts.append_array(PackedVector3Array([
				Vector3(0.0, -0.5, 0.0), Vector3(0.21 * half, -0.12, 0.03),
				Vector3(0.14 * half, 0.24, 0.03), Vector3(0.0, -0.02, -0.02), Vector3(0.0, 0.5, 0.0),
			]))
			for v: float in [0.5, 0.72, 0.78, 0.74, 0.8]:
				colors.append(Color(v * tone, v * tone, v * tone))
			indices.append_array(PackedInt32Array([first, first + 1, first + 3, first + 1, first + 2, first + 3, first + 2, first + 4, first + 3]))
	else:
		verts.append_array(PackedVector3Array([
			Vector3(0.0, -0.5, 0.0), Vector3(0.22, -0.05, 0.0), Vector3(0.0, 0.5, 0.0), Vector3(-0.22, -0.05, 0.0),
		]))
		for v: float in [0.55, 0.74, 0.8, 0.7]:
			colors.append(Color(v, v, v))
		indices.append_array(PackedInt32Array([0, 1, 2, 0, 2, 3]))
	var norms := PackedVector3Array()
	norms.resize(verts.size())
	norms.fill(Vector3.BACK)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _add_tube(verts: PackedVector3Array, norms: PackedVector3Array, indices: PackedInt32Array, points: Array[Vector3], radii: Array[float], sides := 8) -> void:
	var first := verts.size()
	for p in points.size():
		var forward: Vector3
		if p == points.size() - 1:
			forward = (points[p] - points[p - 1]).normalized()
		else:
			forward = (points[p + 1] - points[p]).normalized()
		var side := forward.cross(Vector3(0.31, 0.2, 0.93)).normalized()
		var other := forward.cross(side).normalized()
		for s in sides:
			var a := TAU * float(s) / float(sides)
			var dir := side * cos(a) + other * sin(a)
			verts.append(points[p] + dir * radii[p])
			norms.append(dir)
	for p in points.size() - 1:
		for s in sides:
			var a := first + p * sides + s
			var b := first + p * sides + (s + 1) % sides
			var c := a + sides
			var d := b + sides
			indices.append_array(PackedInt32Array([a, c, b, b, c, d]))


## A curved tapering branch. Returns its points, so smaller branches can grow from it.
static func _add_branch(verts: PackedVector3Array, norms: PackedVector3Array, indices: PackedInt32Array, rng: RandomNumberGenerator, from: Vector3, to: Vector3, r0: float, r1: float, steps: int, sides: int) -> Array[Vector3]:
	var length := from.distance_to(to)
	var bend := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.6, 0.2), rng.randf_range(-1.0, 1.0)) * length * 0.2
	var control := from.lerp(to, 0.5) + bend
	var points: Array[Vector3] = []
	var radii: Array[float] = []
	for s in steps + 1:
		var t := float(s) / float(steps)
		points.append(from.lerp(control, t).lerp(control.lerp(to, t), t))
		radii.append(lerpf(r0, r1, t))
	_add_tube(verts, norms, indices, points, radii, sides)
	return points


## Trunk and branches, grown toward the canopy clumps. Fork height, lean, thickness and
## the number of main limbs all vary, so no two designs share a silhouette.
static func _make_wood(rng: RandomNumberGenerator, height: float, centers: Array[Vector3], radii: Array[float], material: Material) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var indices := PackedInt32Array()
	var girth := rng.randf_range(0.85, 1.25)
	var fork_h := height * rng.randf_range(0.42, 0.78)
	var lean := Vector3(rng.randf_range(-1.1, 1.1), 0.0, rng.randf_range(-1.1, 1.1))
	var phase := rng.randf() * TAU
	var trunk_points: Array[Vector3] = []
	var trunk_radii: Array[float] = []
	var trunk_steps := 7
	for s in trunk_steps:
		var t := float(s) / float(trunk_steps - 1)
		var wander := Vector3(sin(t * 3.0 + phase), 0.0, cos(t * 2.5 + phase)) * 0.18
		trunk_points.append(Vector3.UP * (fork_h * t - 0.6) + lean * t * t + wander)
		# The base flares out where roots would meet the ground.
		trunk_radii.append(lerpf(0.62, 0.4, t) * girth * (1.0 + 0.9 * pow(1.0 - t, 5.0)))
	_add_tube(verts, norms, indices, trunk_points, trunk_radii, 10)

	# Clumps around the crown are shared out between the main limbs by direction.
	var order: Array[int] = []
	for c in range(1, centers.size()):
		order.append(c)
	order.sort_custom(func(a: int, b: int) -> bool: return atan2(centers[a].z, centers[a].x) < atan2(centers[b].z, centers[b].x))
	var limbs := mini(rng.randi_range(2, 4), order.size())
	var shift := rng.randi_range(0, order.size() - 1)
	for limb in limbs:
		var group: Array[int] = []
		for n in range(limb * order.size() / limbs, (limb + 1) * order.size() / limbs):
			group.append(order[(n + shift) % order.size()])
		var average := Vector3.ZERO
		for c in group:
			average += centers[c]
		average /= float(group.size())
		# Limbs leave the trunk at staggered heights instead of from one point.
		var at := rng.randi_range(trunk_steps - 3, trunk_steps - 1)
		var start := trunk_points[at]
		var finish := start.lerp(average, rng.randf_range(0.5, 0.7)) + Vector3(rng.randf_range(-0.4, 0.4), 0.0, rng.randf_range(-0.4, 0.4))
		var r0 := trunk_radii[at] * rng.randf_range(0.62, 0.78)
		var r1 := r0 * 0.55
		_add_branch(verts, norms, indices, rng, start, finish, r0, r1, 4, 7)
		for c in group:
			var twig_end := centers[c] - Vector3.UP * radii[c] * 0.3
			var path := _add_branch(verts, norms, indices, rng, finish, twig_end, r1, 0.07, 3, 6)
			# The side twig ends inside its clump, so no bare stub pokes out under the leaves.
			var side_tip := centers[c] + Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.2, 0.6), rng.randf_range(-1.0, 1.0)) * radii[c] * 0.55
			_add_branch(verts, norms, indices, rng, path[1], side_tip, r1 * 0.45, 0.04, 2, 5)
	if rng.randf() < 0.65:
		var leader_end := centers[0] - Vector3.UP * radii[0] * 0.2
		_add_branch(verts, norms, indices, rng, trunk_points[trunk_steps - 1], leader_end, trunk_radii[trunk_steps - 1] * 0.6, 0.09, 4, 7)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


## One reusable tree design: branching wood, opaque canopy cores, and layered pointed leaves.
static func make_tree_proto(rng: RandomNumberGenerator, palette: Dictionary, leaf_mesh: Mesh, far_leaf_mesh: Mesh, bark: Material, core_mesh: Mesh) -> Dictionary:
	var trunk_h := rng.randf_range(6.0, 8.5)
	# Crown shape: 0 round, 1 wide and flat, 2 tall and uneven.
	var shape := rng.randi_range(0, 2)
	var spread: float = [1.0, 1.35, 0.8][shape]
	var rise: float = [1.0, 0.6, 1.35][shape]
	# Many smaller clumps at uneven heights give a bumpy outline instead of a few big lobes.
	var satellites: int = rng.randi_range([10, 12, 9][shape], [13, 15, 12][shape])
	var crown_y := trunk_h + 3.8
	var offset := Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.8, 0.8))
	var centers: Array[Vector3] = [Vector3(0.0, crown_y, 0.0) + offset * 0.4]
	var radii: Array[float] = [rng.randf_range(3.2, 4.0)]
	for s in satellites:
		# Golden-angle spacing spreads clumps evenly around the crown, then each one is nudged.
		var a := float(s) * 2.39996 + rng.randf_range(-0.3, 0.3)
		var dist := rng.randf_range(2.6, 5.0) * spread
		var up := rng.randf_range(-1.0, 3.2) * rise
		centers.append(Vector3(cos(a) * dist, crown_y + up, sin(a) * dist) + offset)
		radii.append(rng.randf_range(1.7, 2.9))
	var min_y := centers[0].y - radii[0]
	var max_y := centers[0].y + radii[0]
	var total_area := 0.0
	var clump_shades: Array[float] = []
	for c in centers.size():
		min_y = minf(min_y, centers[c].y - radii[c])
		max_y = maxf(max_y, centers[c].y + radii[c])
		total_area += radii[c] * radii[c]
		# Brightness also varies by clump, which keeps the canopy from looking flat.
		clump_shades.append(rng.randf_range(0.92, 1.04))

	var top := _to_linear(palette["top"])
	var mid := _to_linear(palette["mid"])
	var low := _to_linear(palette["low"])
	var core := _to_linear(palette["core"])
	var target := 7000
	var buffer := PackedFloat32Array()
	buffer.resize(target * 20)
	var count := 0
	var tries := 0
	while count < target and tries < target * 4:
		tries += 1
		# Larger clumps get proportionally more leaves, for even coverage.
		var pick := rng.randf() * total_area
		var blob := 0
		while blob < centers.size() - 1 and pick > radii[blob] * radii[blob]:
			pick -= radii[blob] * radii[blob]
			blob += 1
		var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var pos := centers[blob] + dir * radii[blob] * rng.randf_range(0.9, 1.03)
		var covered := false
		var crease := 1.0
		for c in centers.size():
			if c == blob:
				continue
			var inside := pos.distance_to(centers[c]) / radii[c]
			if inside < 0.86:
				covered = true
				break
			crease = minf(crease, smoothstep(0.86, 1.2, inside))
		if covered:
			continue

		# Leaves lie along the clump and hang downward with their tips lifted, like feathers.
		var flow := Vector3.DOWN - dir * dir.dot(Vector3.DOWN)
		if flow.length() < 0.2:
			flow = Vector3(rng.randfn(), 0.0, rng.randfn())
		var scatter := Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * 0.42
		var axis := (flow.normalized() + scatter + dir * 0.38).normalized()
		var facing := (dir - axis * dir.dot(axis)).normalized()
		var across := axis.cross(facing).rotated(axis, rng.randf_range(-0.55, 0.55))
		facing = across.cross(axis).normalized()
		var size := rng.randf_range(0.7, 1.05)
		var basis := Basis(across * size, axis * size, facing * size)

		var k := clampf((pos.y - min_y) / (max_y - min_y), 0.0, 1.0)
		var color: Color = low.lerp(mid, smoothstep(0.0, 0.55, k)).lerp(top, smoothstep(0.5, 1.0, k))
		color = color.lerp(top, rng.randf() * 0.14)
		# Darker where clumps meet and on undersides, plus a little variation between leaves.
		var shade := lerpf(0.72, 1.0, crease) * lerpf(0.9, 1.0, smoothstep(-0.7, 0.45, dir.y)) * rng.randf_range(0.93, 1.06) * clump_shades[blob]
		color = Color(color.r * shade, color.g * shade, color.b * shade)
		# Light follows each clump's own roundness, with a small tilt per leaf.
		var whole := (pos - centers[0]).normalized()
		var tilt := Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * 0.1
		var canopy_normal := (dir * 0.72 + whole * 0.28 + tilt).normalized()
		# The shader's MODEL_MATRIX includes this leaf's rotation, so that rotation is undone here.
		_write_instance(buffer, count * 20, basis, pos, color, (basis.inverse() * canopy_normal).normalized())
		count += 1

	var core_buffer := PackedFloat32Array()
	core_buffer.resize(centers.size() * 20)
	for c in centers.size():
		var r := radii[c] * 0.84
		_write_instance(core_buffer, c * 20, Basis().scaled(Vector3(r, r, r)), centers[c], mid.lerp(core, 0.5), Vector3.UP)

	# Low-detail copy for distant trees: every third leaf, a little larger.
	var far_count := count / 3
	var far_buffer := PackedFloat32Array()
	far_buffer.resize(far_count * 20)
	for n in far_count:
		for k in 20:
			far_buffer[n * 20 + k] = buffer[n * 60 + k]
		for k: int in [0, 1, 2, 4, 5, 6, 8, 9, 10]:
			far_buffer[n * 20 + k] *= 1.6

	return {
		"trunk": _make_wood(rng, trunk_h, centers, radii, bark),
		"leaves": _make_multimesh(leaf_mesh, buffer, count),
		"leaves_far": _make_multimesh(far_leaf_mesh, far_buffer, far_count),
		"cores": _make_multimesh(core_mesh, core_buffer, centers.size()),
	}


static func _place_tree(parent: Node3D, proto: Dictionary, pos: Vector3, yaw: float, scale_factor: float, casts_shadow := true) -> Node3D:
	var tree := Node3D.new()
	tree.position = pos
	tree.rotation.y = yaw
	tree.scale = Vector3.ONE * scale_factor
	parent.add_child(tree)
	var trunk := MeshInstance3D.new()
	trunk.mesh = proto["trunk"]
	tree.add_child(trunk)
	var cores := MultiMeshInstance3D.new()
	cores.multimesh = proto["cores"]
	tree.add_child(cores)
	var far_leaves := MultiMeshInstance3D.new()
	far_leaves.multimesh = proto["leaves_far"]
	# The opaque cores cast the tree's shadow, which is far cheaper than every leaf.
	far_leaves.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	far_leaves.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	tree.add_child(far_leaves)
	if casts_shadow:
		# Trees inside the playable area swap to full detail up close.
		far_leaves.visibility_range_begin = LEAF_LOD_RANGE
		far_leaves.visibility_range_begin_margin = 10.0
		var leaves := MultiMeshInstance3D.new()
		leaves.multimesh = proto["leaves"]
		leaves.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		leaves.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		leaves.visibility_range_end = LEAF_LOD_RANGE
		leaves.visibility_range_end_margin = 10.0
		tree.add_child(leaves)
	if not casts_shadow:
		cores.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		trunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for part in tree.get_children():
		part.layers = LAYER_NO_DECAL
	return tree


static func _tree_spot_ok(terrain, x: float, z: float) -> bool:
	var h: float = terrain.height_at(x, z)
	if h < terrain.WATER_LEVEL + 1.6 or terrain.normal_at(x, z).y < 0.66 or terrain.dig_at(x, z) > 0.1:
		return false
	if terrain.shape.road_distance(x, z) < 13.0:
		return false
	var home: Vector2 = terrain.home_center()
	if Vector2(x - home.x, z - home.y).length() < 26.0:
		return false
	for zone: Vector3 in terrain.shape.keep_clear():
		if Vector2(x - zone.x, z - zone.y).length() < zone.z:
			return false
	return true


## Returns tree positions so petals can gather beneath them, and fills nodes for the sculpting code.
static func build_trees(parent: Node3D, terrain, rng: RandomNumberGenerator, nodes: Array[Node3D]) -> Array[Vector3]:
	var leaf_material := _shader_material("res://shaders/leaf.gdshader")
	var leaf_mesh := make_canopy_leaf_mesh(true)
	leaf_mesh.surface_set_material(0, leaf_material)
	var far_leaf_mesh := make_canopy_leaf_mesh(false)
	far_leaf_mesh.surface_set_material(0, leaf_material)
	var core_material := _shader_material("res://shaders/canopy_core.gdshader")
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 1.0
	core_mesh.height = 2.0
	core_mesh.radial_segments = 14
	core_mesh.rings = 7
	core_mesh.material = core_material
	var bark := _shader_material("res://shaders/solid.gdshader")
	bark.set_shader_parameter("albedo", Color(0.3, 0.2, 0.15))
	bark.set_shader_parameter("noise_scale", 3.0)
	bark.set_shader_parameter("variation", 0.35)

	# Each design has its own crown and branching. The outer groves reuse them with low-detail leaves.
	var pink: Array[Dictionary] = []
	for n in 8:
		pink.append(make_tree_proto(rng, PINK_PALETTE if n % 2 == 0 else PALE_PALETTE, leaf_mesh, far_leaf_mesh, bark, core_mesh))
	var green: Array[Dictionary] = []
	for n in 2:
		green.append(make_tree_proto(rng, GREEN_PALETTE, leaf_mesh, far_leaf_mesh, bark, core_mesh))
	var far_protos: Array[Dictionary] = [pink[0], pink[1], green[0]]

	var noise := FastNoiseLite.new()
	noise.seed = 77
	noise.frequency = 0.022
	var half: float = terrain.SIZE * 0.5
	var placed: Array[Vector3] = []
	var attempts := 0
	var min_spacing := 11.0
	while placed.size() < 150 and attempts < 9000:
		attempts += 1
		var x := rng.randf_range(-half + 3.0, half - 3.0)
		var z := rng.randf_range(-half + 3.0, half - 3.0)
		if noise.get_noise_2d(x, z) < -0.06 or not _tree_spot_ok(terrain, x, z):
			continue
		var spot := Vector3(x, terrain.height_at(x, z), z)
		var crowded := false
		for other in placed:
			if other.distance_squared_to(spot) < min_spacing * min_spacing:
				crowded = true
				break
		if crowded:
			continue
		placed.append(spot)
		var proto: Dictionary = pink[rng.randi_range(0, pink.size() - 1)]
		if rng.randf() < 0.1:
			proto = green[rng.randi_range(0, green.size() - 1)]
		nodes.append(_place_tree(parent, proto, spot, rng.randf() * TAU, rng.randf_range(0.82, 1.28)))
	# Featured trees close to the village and the lake.
	var home: Vector2 = terrain.home_center()
	for offset: Vector2 in [Vector2(-20.0, -14.0), Vector2(24.0, -18.0), Vector2(-27.0, 13.0), Vector2(30.0, 6.0)]:
		var fx := home.x + offset.x
		var fz := home.y + offset.y
		var spot := Vector3(fx, terrain.height_at(fx, fz), fz)
		placed.append(spot)
		nodes.append(_place_tree(parent, pink[placed.size() % pink.size()], spot, rng.randf() * TAU, 1.2))
	# Lower-detail groves just outside the playable area, so the valley continues.
	var far_count := 0
	var far_attempts := 0
	while far_count < 200 and far_attempts < 9000:
		far_attempts += 1
		var x := rng.randf_range(-330.0, 330.0)
		var z := rng.randf_range(-330.0, 330.0)
		if maxf(absf(x), absf(z)) < 172.0 or noise.get_noise_2d(x * 0.6, z * 0.6) < -0.1:
			continue
		var y: float = terrain.base_height(x, z) - 1.2
		if y < terrain.void_level + 3.0:
			continue
		var proto: Dictionary = far_protos[rng.randi_range(0, far_protos.size() - 1)]
		_place_tree(parent, proto, Vector3(x, y, z), rng.randf() * TAU, rng.randf_range(1.0, 1.5), false)
		far_count += 1
	return placed


## Fallen petals: thick drifts beneath trees and scattered patches over the meadow.
static func build_ground_petals(parent: Node3D, terrain, rng: RandomNumberGenerator, petal_map: PackedFloat32Array) -> void:
	var material := _shader_material("res://shaders/solid.gdshader")
	material.set_shader_parameter("variation", 0.0)
	material.set_shader_parameter("ground_rule", 2)
	material.set_shader_parameter("water_level", terrain.WATER_LEVEL)
	terrain.bind_state(material)
	var mesh := make_leaf_mesh()
	mesh.surface_set_material(0, material)
	var target := 140000
	var buffer := PackedFloat32Array()
	buffer.resize(target * 20)
	var count := 0
	var pale := _to_linear(Color(1.0, 0.86, 0.88))
	var pink := _to_linear(Color(0.97, 0.66, 0.73))
	var half: float = terrain.SIZE * 0.5
	for n in target * 8:
		if count >= target:
			break
		var x := rng.randf_range(-half, half)
		var z := rng.randf_range(-half, half)
		if rng.randf() > _petal_amount(terrain, petal_map, x, z) or not _grass_allowed(terrain, x, z):
			continue
		var normal: Vector3 = terrain.normal_at(x, z)
		var up := (normal + Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * 0.18).normalized()
		var tangent := up.cross(Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()).normalized()
		var size := rng.randf_range(0.3, 0.52)
		var basis := Basis(tangent * size, up.cross(tangent) * size, up * size)
		var ground: float = terrain.height_at(x, z)
		var pos := Vector3(x, ground + rng.randf_range(0.55, 0.88), z)
		_write_instance(buffer, count * 20, basis, pos, pink.lerp(pale, rng.randf()), Vector3(ground, 0.0, 0.0))
		count += 1
	var node := MultiMeshInstance3D.new()
	node.multimesh = _make_multimesh(mesh, buffer, count)
	node.custom_aabb = AABB(Vector3(-half, -60.0, -half), Vector3(terrain.SIZE, 260.0, terrain.SIZE))
	node.layers = LAYER_MAIN_ONLY
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(node)


static func build_water_petals(parent: Node3D, terrain, rng: RandomNumberGenerator) -> void:
	var material := _shader_material("res://shaders/solid.gdshader")
	material.set_shader_parameter("variation", 0.0)
	material.set_shader_parameter("ground_rule", 3)
	material.set_shader_parameter("water_level", terrain.WATER_LEVEL)
	terrain.bind_state(material)
	var mesh := make_leaf_mesh()
	mesh.surface_set_material(0, material)
	var target := 2800
	var buffer := PackedFloat32Array()
	buffer.resize(target * 20)
	var count := 0
	var half: float = terrain.SIZE * 0.5
	var pale := _to_linear(Color(1.0, 0.87, 0.89))
	var pink := _to_linear(Color(0.97, 0.66, 0.74))
	var noise := FastNoiseLite.new()
	noise.seed = 19
	noise.frequency = 0.07
	for n in target * 30:
		if count >= target:
			break
		var x := rng.randf_range(-half, half)
		var z := rng.randf_range(-half, half)
		if terrain.water_mask[terrain._index_of(x, z)] == 0 or noise.get_noise_2d(x, z) < -0.05:
			continue
		var yaw := Basis(Vector3.UP, rng.randf() * TAU)
		var flat := yaw * Basis(Vector3.RIGHT, -PI * 0.5)
		var size := rng.randf_range(0.2, 0.34)
		_write_instance(buffer, count * 20, flat.scaled(Vector3(size, size, size)), Vector3(x, terrain.WATER_LEVEL + 0.03, z), pink.lerp(pale, rng.randf()), Vector3.UP)
		count += 1
	var node := MultiMeshInstance3D.new()
	node.multimesh = _make_multimesh(mesh, buffer, count)
	node.layers = LAYER_MAIN_ONLY
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)


## Returns the material, so each light preset can set the petal color directly.
static func build_falling_petals(parent: Node3D) -> StandardMaterial3D:
	var mesh := make_leaf_mesh(0.16)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.76, 0.82)
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.surface_set_material(0, material)
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(165.0, 30.0, 165.0)
	process.direction = Vector3(0.8, -0.2, 0.45)
	process.spread = 25.0
	process.initial_velocity_min = 0.7
	process.initial_velocity_max = 1.9
	process.gravity = Vector3(0.0, -0.32, 0.0)
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.angular_velocity_min = -90.0
	process.angular_velocity_max = 90.0
	process.scale_min = 0.7
	process.scale_max = 1.5
	var particles := GPUParticles3D.new()
	particles.amount = 7000
	particles.lifetime = 38.0
	particles.preprocess = 38.0
	particles.draw_pass_1 = mesh
	particles.process_material = process
	particles.position = Vector3(0.0, 32.0, 0.0)
	particles.visibility_aabb = AABB(Vector3(-190.0, -60.0, -190.0), Vector3(380.0, 120.0, 380.0))
	particles.layers = LAYER_MAIN_ONLY
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(particles)
	return material
