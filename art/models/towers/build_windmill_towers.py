"""Builds the three windmill-and-canvas towers in their own Blender scene, "WindmillTowers".

Run inside Blender (Scripting tab, or through the BlenderMCP add-on). Running it again rebuilds the scene.
  build()             the three towers, unupgraded, side by side
  build_lineup()      a second scene, "TowerUpgrades", with every upgrade state in a row per tower
  export_glb(folder)  writes cannon.glb, catapult.glb and sniper.glb for the game
                      (sakura_valley/assets/models/towers), each holding every upgrade part

Game conventions (see scripts/tower_models.gd, data/tower_models.json and data/towers.json):
- Metres. Blender Z is up. The gun points along Blender -Y, which glTF export turns into Godot +Z.
- Each tower is a root empty at ground level holding the static base, a "<Name>_Yaw" empty at deck
  height that turns about Z, and a "<Name>_Pitch" empty at the gun pivot that tilts about X.
  Pivot heights match pivot_height in towers.json: cannon 10.6, catapult 7.6, sniper 13.6.
- "<Name>_Muzzle..." marks where shots leave. "<Name>_Vanes..." is a windmill rotor; it spins about Blender X
  (Godot X), its hub's outward axis.
- Upgrade parts carry the custom properties wt_requires / wt_unless (see Variant), exported as glTF extras.
- Material names (WT_ash, WT_sky, ...) are what the game keys its own materials on. WT_sky is the
  accent slot that each upgrade recolours.
- The catapult arm is modelled level; the game tips it to its resting angle and swings it when throwing.
"""

import math
import random

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

SCENE_NAME = "WindmillTowers"
FORWARD = Vector((0.0, -1.0, 0.0))

rng = random.Random(20261106)
MATS = {}


# ---------------------------------------------------------------- materials

def _principled(mat):
	"""The material's Principled BSDF, made and wired to the output if the material has none."""
	if mat.node_tree is None:
		mat.use_nodes = True
	nodes = mat.node_tree.nodes
	for node in nodes:
		if node.type == "BSDF_PRINCIPLED":
			return node
	nodes.clear()
	bsdf = nodes.new("ShaderNodeBsdfPrincipled")
	out = nodes.new("ShaderNodeOutputMaterial")
	out.location = (300.0, 0.0)
	mat.node_tree.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
	return bsdf


def _linear(c):
	return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def material(name, srgb, rough=0.85, metal=0.0, emit=0.0):
	"""Colours are given as they look on screen (sRGB) and stored linear, as Blender expects."""
	rgb = tuple(_linear(c) for c in srgb)
	key = "WT_" + name
	mat = bpy.data.materials.get(key) or bpy.data.materials.new(key)
	bsdf = _principled(mat)
	bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
	bsdf.inputs["Roughness"].default_value = rough
	bsdf.inputs["Metallic"].default_value = metal
	if "Emission Color" in bsdf.inputs:
		bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
		bsdf.inputs["Emission Strength"].default_value = emit
	mat.diffuse_color = (*rgb, 1.0)
	mat.use_backface_culling = True
	_tint_by_vertex_colour(mat, bsdf, rgb)
	MATS[name] = mat
	return mat


def _tint_by_vertex_colour(mat, bsdf, rgb):
	"""Base colour times the mesh's "Col" attribute, so every timber and panel can differ a little.
	glTF exports this as COLOR_0, which multiplies the base colour in Godot too."""
	nodes, links = mat.node_tree.nodes, mat.node_tree.links
	for node in list(nodes):
		if node.name in ("WT_tint", "WT_mul"):
			nodes.remove(node)
	attr = nodes.new("ShaderNodeVertexColor")
	attr.name = "WT_tint"
	attr.layer_name = "Col"
	attr.location = (-500.0, 200.0)
	mul = nodes.new("ShaderNodeMix")
	mul.name = "WT_mul"
	mul.data_type = "RGBA"
	mul.blend_type = "MULTIPLY"
	mul.location = (-250.0, 200.0)
	sockets_a = [s for s in mul.inputs if s.name == "A" and s.type == "RGBA"]
	sockets_b = [s for s in mul.inputs if s.name == "B" and s.type == "RGBA"]
	result = next(s for s in mul.outputs if s.type == "RGBA")
	mul.inputs[0].default_value = 1.0
	sockets_a[0].default_value = (*rgb, 1.0)
	links.new(attr.outputs["Color"], sockets_b[0])
	links.new(result, bsdf.inputs["Base Color"])


def make_materials():
	material("ash", (0.71, 0.56, 0.39), 0.8)  # pale timber frame
	material("ash_dark", (0.45, 0.32, 0.21), 0.85)  # braces, rungs, older wood
	material("canvas", (0.89, 0.85, 0.75), 0.9)
	material("sky", (0.50, 0.67, 0.85), 0.9)  # faded sky-blue stripes and banners
	material("whitewash", (0.88, 0.86, 0.81), 0.95)
	material("iron", (0.24, 0.24, 0.26), 0.5, 0.6)
	material("rope", (0.70, 0.60, 0.43), 0.95)
	material("stone", (0.62, 0.60, 0.56), 0.9)
	material("grass", (0.44, 0.56, 0.28), 1.0)
	# Upgrade accents.
	material("brass", (0.80, 0.64, 0.32), 0.4, 0.8)  # star ranks
	material("bronze", (0.62, 0.45, 0.26), 0.45, 0.8)
	material("ember", (1.0, 0.52, 0.18), 0.6, emit=3.0)  # fire lines
	material("clay", (0.70, 0.43, 0.29), 0.9)
	material("starstone", (0.86, 0.90, 0.98), 0.3, emit=0.6)  # meteor
	material("shell", (0.80, 0.47, 0.25), 0.6, 0.3)  # bursting rounds
	material("soot", (0.10, 0.09, 0.09), 0.9)  # the inside of a gun mouth
	for name, srgb in ACCENTS.items():
		material("accent_" + name, srgb, 0.9)


# Every upgrade repaints the tower's cloth. The accent colour (stripes, flags, sails, gun bands) says
# what the upgrade does, using the same colour for the same job on every tower, and the stripe
# pattern says which of the two lines was taken. In the game this belongs in towers.json and a
# canvas shader; the tables here drive the Blender previews.
ACCENTS = {
	"honey": (0.88, 0.72, 0.38),  # speed and spread
	"brick": (0.76, 0.34, 0.25),  # fire and blast
	"teal": (0.30, 0.60, 0.52),  # range and sight
	"charcoal": (0.24, 0.24, 0.27),  # weight
	"plum": (0.52, 0.36, 0.50),  # earth, shock and pinning
	"indigo": (0.30, 0.34, 0.66),  # falling stars
}
UPGRADE_ACCENT = {
	"scatter": "honey", "fan": "honey", "blaze": "brick", "heavy": "charcoal", "lofty": "teal", "quake": "plum",
	"boulder": "charcoal", "meteor": "indigo", "rubble": "plum", "volley": "honey", "firepot": "brick", "farthrow": "teal",
	"quick": "honey", "twin": "honey", "eagle": "teal", "heavyshot": "charcoal", "pin": "plum", "burst": "brick",
}
# First-tier upgrades set the stripe pattern for their whole line: "bands" is the unupgraded look.
LINE_PATTERN = {
	"scatter": "vertical", "boulder": "vertical", "quick": "vertical",
	"heavy": "dipped", "volley": "dipped", "heavyshot": "dipped",
}
STYLE = {"accent": "sky", "pattern": "bands"}


def set_style(path):
	"""Picks the cloth accent and stripe pattern for an upgrade state; None or () is the base look."""
	STYLE["accent"], STYLE["pattern"] = "sky", "bands"
	for up in path or ():
		if up in LINE_PATTERN:
			STYLE["pattern"] = LINE_PATTERN[up]
			STYLE["accent"] = "accent_" + UPGRADE_ACCENT[up]
	for up in path or ():
		if up in UPGRADE_ACCENT and up not in LINE_PATTERN:
			STYLE["accent"] = "accent_" + UPGRADE_ACCENT[up]


# ---------------------------------------------------------------- scene graph

# Upgrade variants. PATH["value"] is the set of upgrade ids (and "star1".."star3") to build for a
# preview, or None to build every variant at once for export. Every object made inside a Variant
# block is stamped with custom properties the game can read:
#   wt_requires = "a,b"  show only when all these ids are on the tower's path
#   wt_unless   = "c,d"  hide when any of these ids is on the path (the part they replace)
PATH = {"value": ()}
TAGS = []


class Variant:
	def __init__(self, requires=(), unless=()):
		self.requires, self.unless = tuple(requires), tuple(unless)

	def __enter__(self):
		TAGS.append((self.requires, self.unless))
		path = PATH["value"]
		if path is None:
			return True
		need = [r for req, _ in TAGS for r in req]
		avoid = [u for _, unl in TAGS for u in unl]
		return all(r in path for r in need) and not any(u in path for u in avoid)

	def __exit__(self, *exc):
		TAGS.pop()
		return False


def _stamp(obj):
	need = sorted({r for req, _ in TAGS for r in req})
	avoid = sorted({u for _, unl in TAGS for u in unl})
	if need:
		obj["wt_requires"] = ",".join(need)
	if avoid:
		obj["wt_unless"] = ",".join(avoid)


class Node:
	"""An empty with a known tower-local origin, so children can be placed in tower-local metres."""

	def __init__(self, name, origin, parent=None, collection=None):
		self.obj = bpy.data.objects.new(name, None)
		_stamp(self.obj)
		self.obj.empty_display_size = 0.6
		self.origin = Vector(origin)
		self.collection = collection or parent.collection
		self.collection.objects.link(self.obj)
		if parent is not None:
			self.obj.parent = parent.obj
			self.obj.location = self.origin - parent.origin
		else:
			self.obj.location = self.origin


def place(name, bm, mat, node, at, rotation=None):
	"""Turns a bmesh built around (0, 0, 0) into an object at tower-local point `at` under `node`."""
	mesh = bpy.data.meshes.new(name)
	bm.to_mesh(mesh)
	bm.free()
	mats = mat if isinstance(mat, (list, tuple)) else [mat]
	# "sky" is the accent slot: it takes the current upgrade's colour.
	mats = [STYLE["accent"] if m == "sky" else m for m in mats]
	for m in mats:
		mesh.materials.append(MATS[m])
	for poly in mesh.polygons:
		poly.use_smooth = False
	_paint_variation(mesh)
	obj = bpy.data.objects.new(name, mesh)
	_stamp(obj)
	node.collection.objects.link(obj)
	obj.parent = node.obj
	obj.location = Vector(at) - node.origin
	if rotation is not None:
		obj.rotation_mode = "QUATERNION"
		obj.rotation_quaternion = rotation
	return obj


def _paint_variation(mesh):
	"""A per-object tint (each timber a slightly different board) plus faint per-face mottling."""
	attr = mesh.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
	base = rng.uniform(0.86, 1.06)
	warm = rng.uniform(-0.03, 0.03)
	for poly in mesh.polygons:
		f = base * rng.uniform(0.96, 1.03)
		colour = (min(f * (1.0 + warm), 1.0), min(f, 1.0), min(f * (1.0 - warm), 1.0), 1.0)
		for loop in poly.loop_indices:
			attr.data[loop].color = colour
	mesh.color_attributes.active_color = attr


def _bevel(bm, width):
	if width > 0.0:
		bmesh.ops.bevel(bm, geom=list(bm.edges) + list(bm.verts), offset=width, segments=1, affect="EDGES", clamp_overlap=True)


def box(name, size, at, mat, node, rotation=None, bevel=None):
	bm = bmesh.new()
	bmesh.ops.create_cube(bm, size=1.0)
	for v in bm.verts:
		v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
	_bevel(bm, min(size) * 0.12 if bevel is None else bevel)
	rot = rotation.to_quaternion() if isinstance(rotation, Euler) else rotation
	return place(name, bm, mat, node, at, rot)


def beam(name, a, b, width, mat, node, depth=None, roll=0.0):
	"""A squared timber from tower-local point a to point b."""
	a, b = Vector(a), Vector(b)
	axis = b - a
	length = axis.length
	bm = bmesh.new()
	bmesh.ops.create_cube(bm, size=1.0)
	d = width if depth is None else depth
	for v in bm.verts:
		v.co = Vector((v.co.x * width, v.co.y * d, v.co.z * length))
	_bevel(bm, min(width, d) * 0.14)
	rot = axis.to_track_quat("Z", "Y")
	if roll:
		rot = rot @ Euler((0.0, 0.0, roll)).to_quaternion()
	return place(name, bm, mat, node, (a + b) * 0.5, rot)


def cylinder(name, r1, r2, depth, segments, at, mat, node, axis=(0.0, 0.0, 1.0), caps=True):
	bm = bmesh.new()
	bmesh.ops.create_cone(bm, cap_ends=caps, cap_tris=False, segments=segments, radius1=r1, radius2=r2, depth=depth)
	rot = Vector(axis).to_track_quat("Z", "Y")
	return place(name, bm, mat, node, at, rot)


def sphere(name, radius, at, mat, node, squash=(1.0, 1.0, 1.0), detail=1):
	bm = bmesh.new()
	bmesh.ops.create_icosphere(bm, subdivisions=detail, radius=radius)
	for v in bm.verts:
		v.co = Vector((v.co.x * squash[0], v.co.y * squash[1], v.co.z * squash[2]))
	return place(name, bm, mat, node, at)


CLOTH = 0.035  # how far apart the two faces of a cloth sit, in metres


def canvas(name, corners, node, sag=0.25, outward=None, stripes=((0.58, 0.7),), cols=6, rows=6, scallop=0.0):
	"""A cloth panel over four tower-local corners (bottom-left, bottom-right, top-right, top-left).
	It billows by `sag` metres along `outward`, bands of v in `stripes` are sky blue, and `scallop`
	lifts the bottom corners so the lower edge hangs in a swag. Both faces are modelled."""
	p = [Vector(c) for c in corners]
	centre = (p[0] + p[1] + p[2] + p[3]) * 0.25
	if outward is None:
		outward = (p[1] - p[0]).cross(p[3] - p[0]).normalized()
	outward = Vector(outward).normalized()
	bm = bmesh.new()
	# UVs tell the game's cloth shader (shaders/tower_cloth.gdshader) how to redraw the stripes for an
	# upgrade: x = 1 + u * cols, y = 1 + v on panels that follow the pattern, (0, 0) on panels that keep
	# their modelled colours (banners, narrow sails), and on every non-cloth mesh.
	uv_layer = bm.loops.layers.uv.new("UVMap")
	uvs = {}
	patterned = not any(lo <= 0.0 and hi >= 1.0 for lo, hi in stripes) and cols >= 3
	front, back = [], []
	for j in range(rows + 1):
		v = j / rows
		row_f, row_b = [], []
		for i in range(cols + 1):
			u = i / cols
			bottom = p[0].lerp(p[1], u) + Vector((0.0, 0.0, scallop * (1.0 - math.sin(math.pi * u))))
			top = p[3].lerp(p[2], u)
			point = bottom.lerp(top, v)
			# Cloth hangs from its top edge, so the belly sits low.
			bulge = math.sin(math.pi * u) * math.sin(math.pi * min(v * 1.15, 1.0)) * sag
			point += outward * bulge + Vector((0.0, 0.0, -0.08 * bulge))
			row_f.append(bm.verts.new(point - centre + outward * (CLOTH * 0.5)))
			row_b.append(bm.verts.new(point - centre - outward * (CLOTH * 0.5)))
			uvs[row_f[-1]] = uvs[row_b[-1]] = (1.0 + u * cols, 1.0 + v) if patterned else (0.0, 0.0)
		front.append(row_f)
		back.append(row_b)
	# Work out which winding faces outward from the first quad, so either corner order works.
	probe = (front[0][1].co - front[0][0].co).cross(front[1][0].co - front[0][0].co)
	flip = probe.dot(outward) < 0.0
	for j in range(rows):
		for i in range(cols):
			v = (j + 0.5) / rows
			index = 1 if _accent_cell(i, v, stripes, cols) else 0
			quad_f = [front[j][i], front[j][i + 1], front[j + 1][i + 1], front[j + 1][i]]
			quad_b = [back[j][i], back[j + 1][i], back[j + 1][i + 1], back[j][i + 1]]
			if flip:
				quad_f.reverse()
				quad_b.reverse()
			for quad in (quad_f, quad_b):
				face = bm.faces.new(quad)
				face.material_index = index
				for loop in face.loops:
					loop[uv_layer].uv = uvs[loop.vert]
	return place(name, bm, ["canvas", "sky"], node, centre)


def _accent_cell(i, v, stripes, cols):
	"""Whether a cloth cell takes the accent colour. Panels that are all accent (banners) stay so;
	other panels follow the upgrade's stripe pattern. Keep in step with shaders/tower_cloth.gdshader."""
	if any(lo <= 0.0 and hi >= 1.0 for lo, hi in stripes) or STYLE["pattern"] == "bands" or cols < 3:
		return any(lo <= v <= hi for lo, hi in stripes)
	if STYLE["pattern"] == "vertical":
		return i % 2 == 1
	return v < 0.4 or 0.55 <= v <= 0.68  # "dipped": the hem is dyed, with one band above it


def flag(name, pole_top, length, height, node, direction=(1.0, 0.0, 0.0), mat="sky", tails=True):
	"""A pennant flying from pole_top, with a little wave."""
	top = Vector(pole_top)
	d = Vector(direction).normalized()
	bm = bmesh.new()
	cols = 6
	side = d.cross(Vector((0.0, 0.0, 1.0))).normalized()
	sheets = []
	for offset in (CLOTH * 0.5, -CLOTH * 0.5):
		upper, lower = [], []
		for i in range(cols + 1):
			u = i / cols
			wave = side * (math.sin(u * math.pi * 2.0) * 0.12 * u + offset)
			h = height * (1.0 - 0.75 * u) if tails else height
			upper.append(bm.verts.new(d * (length * u) + wave))
			lower.append(bm.verts.new(d * (length * u) + wave + Vector((0.0, 0.0, -h))))
		sheets.append((upper, lower))
	(uf, lf), (ub, lb) = sheets
	for i in range(cols):
		bm.faces.new((lf[i], lf[i + 1], uf[i + 1], uf[i]))
		bm.faces.new((ub[i], ub[i + 1], lb[i + 1], lb[i]))
	return place(name, bm, mat, node, top)


# ---------------------------------------------------------------- reusable parts

def whitewash_footing(prefix, at, node, size=1.35, height=1.0):
	"""A few whitewashed stone blocks stacked under a leg."""
	at = Vector(at)
	box(prefix, (size, size, height * 0.62), at + Vector((0.0, 0.0, height * 0.31)), "whitewash", node,
		Euler((0.0, 0.0, rng.uniform(-0.12, 0.12))), bevel=0.1)
	box(prefix + "_cap", (size * 0.82, size * 0.82, height * 0.4), at + Vector((0.0, 0.0, height * 0.8)), "whitewash", node,
		Euler((0.0, 0.0, rng.uniform(-0.2, 0.2))), bevel=0.08)
	for n in range(3):
		a = rng.uniform(0.0, math.tau)
		r = size * rng.uniform(0.62, 0.8)
		s = rng.uniform(0.32, 0.5)
		box(f"{prefix}_rubble{n}", (s, s * 0.9, s * 0.6), at + Vector((math.cos(a) * r, math.sin(a) * r, s * 0.25)), "stone", node,
			Euler((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), a)), bevel=0.06)


def railing(prefix, centre_z, radius, posts, height, node, gap=None, width=0.16, cx=0.0, cy=0.0):
	"""Posts and two rails round a deck. `gap` leaves out the rail facing that angle (for a ladder)."""
	pts = []
	for n in range(posts):
		a = n * math.tau / posts + math.pi / posts
		pts.append(Vector((cx + math.cos(a) * radius, cy + math.sin(a) * radius, centre_z)))
		beam(f"{prefix}_post{n}", pts[-1], pts[-1] + Vector((0.0, 0.0, height)), width, "ash", node)
	for n in range(posts):
		a0 = n * math.tau / posts + math.pi / posts
		if gap is not None and abs(((a0 + math.pi / posts - gap + math.pi) % math.tau) - math.pi) < 0.01:
			continue
		p0, p1 = pts[n], pts[(n + 1) % posts]
		beam(f"{prefix}_rail{n}", p0 + Vector((0.0, 0.0, height)), p1 + Vector((0.0, 0.0, height)), width * 0.85, "ash", node)
		beam(f"{prefix}_mid{n}", p0 + Vector((0.0, 0.0, height * 0.5)), p1 + Vector((0.0, 0.0, height * 0.5)), width * 0.6, "ash_dark", node)


def ladder(prefix, bottom, top, width, node):
	bottom, top = Vector(bottom), Vector(top)
	along = top - bottom
	side = along.cross(Vector((0.0, 0.0, 1.0)))
	if side.length < 1e-4:
		side = Vector((1.0, 0.0, 0.0))
	side = side.normalized() * (width * 0.5)
	beam(prefix + "_railL", bottom - side, top - side, 0.11, "ash_dark", node)
	beam(prefix + "_railR", bottom + side, top + side, 0.11, "ash_dark", node)
	rungs = int(along.length / 0.45)
	for n in range(1, rungs):
		p = bottom.lerp(top, n / rungs)
		beam(f"{prefix}_rung{n}", p - side, p + side, 0.07, "ash_dark", node)


def vanes(name, hub, outward, radius, parent, blades=4):
	"""A windmill rotor on the face of a tower. The returned node spins about its local Y axis,
	which is set up to point along `outward`."""
	outward = Vector(outward).normalized()
	node = Node(name, hub, parent)
	# Turn the rotor node so its local Y is the spin axis; children are placed in tower-local space
	# before the turn, so build them first in an axis-aligned frame and then rotate the node.
	up = Vector((0.0, 0.0, 1.0))
	side = outward.cross(up).normalized()
	hub_v = Vector(hub)
	cylinder(name + "_hub", 0.42, 0.34, 0.6, 10, hub_v + outward * 0.3, "ash_dark", node, axis=outward)
	cylinder(name + "_axle", 0.12, 0.12, 1.2, 8, hub_v - outward * 0.3, "iron", node, axis=outward)
	for n in range(blades):
		a = n * math.tau / blades + 0.35
		d = (up * math.cos(a) + side * math.sin(a)).normalized()
		trail = outward.cross(d).normalized()
		face = hub_v + outward * 0.5
		beam(f"{name}_spar{n}", face, face + d * radius, 0.17, "ash", node)
		# An open lattice on the trailing side of each spar: an outer rail and evenly spaced bars,
		# with a sail that tapers toward the hub and carries a blue band near the tip.
		inner, outer = face + d * (radius * 0.24), face + d * radius
		width = radius * 0.3
		lift = outward * 0.06
		beam(f"{name}_edge{n}", inner + trail * width * 0.7 + lift, outer + trail * width + lift, 0.07, "ash_dark", node)
		bars = 5
		for k in range(bars + 1):
			t = k / bars
			root = inner.lerp(outer, t) + lift
			beam(f"{name}_bar{n}_{k}", root, root + trail * width * (0.7 + 0.3 * t), 0.05, "ash", node)
		canvas(f"{name}_sail{n}", (inner + trail * 0.05, inner + trail * width * 0.68, outer + trail * width * 0.97, outer + trail * 0.05), node,
			sag=0.1, outward=outward, stripes=((0.72, 0.86),), cols=2, rows=6)
	return node


def hanging_load(prefix, arm_from, arm_to, drop, node, kind="sack"):
	"""A short jib with a pulley, a rope and a sack or crate hanging from it."""
	arm_from, arm_to = Vector(arm_from), Vector(arm_to)
	beam(prefix + "_jib", arm_from, arm_to, 0.16, "ash", node)
	beam(prefix + "_brace", arm_from + Vector((0.0, 0.0, -1.2)), arm_from.lerp(arm_to, 0.6), 0.12, "ash_dark", node)
	cylinder(prefix + "_pulley", 0.22, 0.22, 0.1, 10, arm_to + Vector((0.0, 0.0, -0.2)), "ash_dark", node,
		axis=(arm_to - arm_from).cross(Vector((0.0, 0.0, 1.0))))
	bottom = arm_to + Vector((0.0, 0.0, -drop))
	beam(prefix + "_rope", arm_to + Vector((0.0, 0.0, -0.2)), bottom, 0.04, "rope", node)
	if kind == "crate":
		box(prefix + "_crate", (0.7, 0.7, 0.6), bottom + Vector((0.0, 0.0, -0.3)), "ash_dark", node)
	else:
		sphere(prefix + "_sack", 0.38, bottom + Vector((0.0, 0.0, -0.32)), "canvas", node, squash=(0.9, 0.9, 1.25))


def frame_legs(prefix, foot, top, levels, node, braces=True, leg_width=0.34):
	"""Four legs leaning in from foot (half width at the ground) to top (half width at the deck),
	ring beams at each height in `levels`, and X braces between neighbouring levels."""
	corners = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
	z0, z1 = levels[0], levels[-1]

	def at(sx, sy, z):
		t = (z - z0) / (z1 - z0)
		w = foot + (top - foot) * t
		return Vector((sx * w, sy * w, z))

	for n, (sx, sy) in enumerate(corners):
		beam(f"{prefix}_leg{n}", at(sx, sy, z0 - 0.1), at(sx, sy, z1 + 0.2), leg_width, "ash", node)
	for k, z in enumerate(levels):
		for n in range(4):
			a, b = corners[n], corners[(n + 1) % 4]
			beam(f"{prefix}_ring{k}_{n}", at(*a, z), at(*b, z), leg_width * 0.7, "ash", node)
	if braces:
		for k in range(len(levels) - 1):
			za, zb = levels[k], levels[k + 1]
			for n in range(4):
				a, b = corners[n], corners[(n + 1) % 4]
				beam(f"{prefix}_x{k}_{n}a", at(*a, za), at(*b, zb), leg_width * 0.5, "ash_dark", node)
				beam(f"{prefix}_x{k}_{n}b", at(*b, za), at(*a, zb), leg_width * 0.5, "ash_dark", node)
	return at


def deck(prefix, z, radius, thickness, node, sides=8):
	cylinder(prefix + "_deck", radius, radius * 0.97, thickness, sides, (0.0, 0.0, z - thickness * 0.5), "ash", node)
	# Planks show as thin dark seams on top.
	for n in range(-int(radius) * 2, int(radius) * 2 + 1):
		x = n * 0.45
		half = math.sqrt(max(radius * radius * 0.86 - x * x, 0.0))
		if half > 0.3:
			box(f"{prefix}_seam{n}", (0.04, half * 2.0, 0.02), (x, 0.0, z + 0.005), "ash_dark", node, bevel=0.0)


# ---------------------------------------------------------------- towers
#
# Upgrade looks. Each line keeps the tower's own silhouette and adds one big readable cue per tier:
# tier 1 swaps the weapon, tier 2 adds a second change on the weapon and one on the tower itself,
# and each star adds a brass ring on the weapon and a brass pennant on the flagpole.

def leg_bands(prefix, at, heights, node, width=0.52):
	"""Iron straps round each leg: the tower has been reinforced to take heavier recoil."""
	for n, (sx, sy) in enumerate([(1, 1), (-1, 1), (-1, -1), (1, -1)]):
		for k, z in enumerate(heights):
			box(f"{prefix}_band{n}_{k}", (width, width, 0.16), at(sx, sy, z), "iron", node, bevel=0.03)


def bunting(prefix, start, end, count, node, drop=0.5):
	"""A sagging rope of little triangular flags, alternating cream and blue."""
	start, end = Vector(start), Vector(end)
	along = end - start
	side = along.cross(Vector((0.0, 0.0, 1.0))).normalized()
	points = []
	for k in range(count + 1):
		t = k / count
		points.append(start.lerp(end, t) + Vector((0.0, 0.0, -drop * 4.0 * t * (1.0 - t))))
	for k in range(count):
		beam(f"{prefix}_rope{k}", points[k], points[k + 1], 0.03, "rope", node)
		a, b = points[k], points[k + 1]
		tip = (a + b) * 0.5 + Vector((0.0, 0.0, -0.55))
		bm = bmesh.new()
		centre = (a + b + tip) / 3.0
		for offset in (CLOTH * 0.5, -CLOTH * 0.5):
			vs = [bm.verts.new(v - centre + side * offset) for v in (a, b, tip)]
			face = bm.faces.new(vs if offset > 0 else list(reversed(vs)))
		place(f"{prefix}_flag{k}", bm, "sky" if k % 2 else "canvas", node, centre)


def star_ranks(prefix, pitch, ring_at, ring_radius, axis, pole_top, root):
	"""Stars: a brass ring on the weapon and a brass pennant on the flagpole for each rank."""
	for s in (1, 2, 3):
		with Variant((f"star{s}",)) as on:
			if on:
				cylinder(f"{prefix}_star_ring{s}", ring_radius, ring_radius, 0.14, 16, Vector(ring_at) + Vector(axis) * (0.32 * s),
					"brass", pitch, axis=axis)
				flag(f"{prefix}_star_pennant{s}", Vector(pole_top) + Vector((0.0, 0.0, -0.5 - 0.5 * s)), 0.9, 0.36, root,
					direction=(1.0, 0.3, 0.0), mat="brass")


def build_cannon(root):
	"""A sturdy windmill tower. Deck at 8.1 m, gun pivot at 10.6 m.
	Lines: scatter (bell mouth) -> fan (three splayed barrels, fan crest, bunting)
	                            -> blaze (fire box, glowing mouth, fire basket, oil barrels)
	       heavy (long banded barrel, iron straps, sandbags) -> lofty (telescope, crow's nest)
	                                                       -> quake (stone muzzle ring, gong, stone plinths)"""
	DECK, PIVOT = 8.1, 10.6
	corners = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
	for n, (sx, sy) in enumerate(corners):
		whitewash_footing(f"Cannon_foot{n}", (sx * 2.7, sy * 2.7, 0.0), root, size=1.5, height=1.05)
	at = frame_legs("Cannon_frame", 2.7, 1.75, [1.0, 4.5, DECK - 0.35], root)
	for n, ((ax, ay), (bx, by)) in enumerate([((1, -1), (-1, -1)), ((1, 1), (1, -1)), ((-1, 1), (1, 1))]):
		bl, br = at(ax, ay, 3.4), at(bx, by, 3.4)
		tl, tr = at(ax, ay, 7.5), at(bx, by, 7.5)
		mid = (bl + br) * 0.5
		out = Vector((mid.x, mid.y, 0.0)).normalized()
		inset = 0.18 if n != 2 else 0.6
		canvas(f"Cannon_skirt{n}", (bl.lerp(br, inset * 0.3) + out * 0.2, br.lerp(bl, inset * 0.3) + out * 0.2, tr + out * 0.2, tl + out * 0.2), root,
			sag=0.55, outward=out, stripes=((0.18, 0.28), (0.66, 0.76)))
	deck("Cannon", DECK, 3.0, 0.4, root)
	railing("Cannon_rail", DECK, 2.8, 8, 1.0, root, gap=math.pi * 0.5)
	ladder("Cannon_ladder", (0.0, 3.4, 0.0), (0.0, 2.15, DECK), 0.8, root)
	with Variant(unless=("fan",)) as on:
		if on:
			vanes("Cannon_Vanes", (-2.15, 0.0, 6.4), (-1.0, 0.0, 0.0), 3.6, root)
	with Variant(("fan",)) as on:
		if on:
			# The windmill itself becomes a great eight-bladed fan.
			vanes("Cannon_Vanes_fan", (-2.15, 0.0, 6.4), (-1.0, 0.0, 0.0), 4.1, root, blades=8)
	hanging_load("Cannon_hoist", at(1, 1, 6.2), at(1, 1, 6.2) + Vector((1.6, 0.5, 0.3)), 2.2, root)
	pole_top = Vector((-2.0, 2.0, DECK + 3.5))
	beam("Cannon_flagpole", (-2.0, 2.0, DECK), (-2.0, 2.0, DECK + 3.6), 0.12, "ash", root)
	flag("Cannon_flag", pole_top, 1.4, 0.7, root, direction=(1.0, 0.3, 0.0))
	with Variant(unless=("scatter",)) as on:
		if on:
			box("Cannon_shot_crate", (0.8, 0.6, 0.45), (1.6, 1.4, DECK + 0.22), "ash_dark", root)
			for n in range(4):
				sphere(f"Cannon_ball{n}", 0.17, (1.4 + (n % 2) * 0.36, 1.32 + (n // 2) * 0.3, DECK + 0.6), "iron", root)
	with Variant(("scatter",)) as on:
		if on:
			# Sacks of loose shot instead of round balls.
			for n, (x, y) in enumerate(((1.5, 1.2), (1.9, 0.7), (1.1, 1.7))):
				sphere(f"Cannon_grapeshot{n}", 0.36, (x, y, DECK + 0.32), "canvas", root, squash=(1.0, 0.9, 0.85))
	with Variant(("fan",)) as on:
		if on:
			# Bunting strung round the top of the canvas skirts, below the deck so the gun clears it.
			for n, ((ax, ay), (bx, by)) in enumerate([((1, -1), (-1, -1)), ((1, 1), (1, -1)), ((-1, -1), (-1, 1))]):
				a, b = at(ax, ay, 7.75), at(bx, by, 7.75)
				mid = (a + b) * 0.5
				out = Vector((mid.x, mid.y, 0.0)).normalized()
				bunting(f"Cannon_bunting{n}", a + out * 0.45, b + out * 0.45, 6, root, drop=0.45)
	with Variant(("blaze",)) as on:
		if on:
			# A stone furnace and chimney built against the right side, glowing at the top, and oil barrels on deck.
			cx, cy = 3.75, -0.4
			box("Cannon_furnace", (1.7, 1.8, 1.7), (cx, cy, 0.85), "stone", root, bevel=0.12)
			box("Cannon_furnace_cap", (1.9, 2.0, 0.22), (cx, cy, 1.75), "whitewash", root, bevel=0.06)
			box("Cannon_furnace_door", (0.8, 0.08, 0.75), (cx, cy - 0.9, 0.6), "ember", root, bevel=0.0)
			box("Cannon_furnace_lintel", (1.1, 0.2, 0.2), (cx, cy - 0.94, 1.08), "iron", root, bevel=0.03)
			cylinder("Cannon_chimney", 0.62, 0.5, 7.6, 10, (cx, cy, 1.86 + 3.8), "stone", root)
			cylinder("Cannon_chimney_soot", 0.53, 0.5, 1.1, 10, (cx, cy, 9.0), "soot", root)
			for k, z in enumerate((3.4, 5.6, 7.8)):
				cylinder(f"Cannon_chimney_hoop{k}", 0.62, 0.62, 0.16, 10, (cx, cy, z), "iron", root)
			cylinder("Cannon_chimney_cap", 0.68, 0.56, 0.3, 10, (cx, cy, 9.6), "iron", root)
			sphere("Cannon_chimney_glow", 0.5, (cx, cy, 9.8), "ember", root, squash=(1.0, 1.0, 0.45))
			for k, (sx, sy) in enumerate(((1, -1), (1, 1))):
				beam(f"Cannon_chimney_tie{k}", at(sx, sy, 5.6), (cx - 0.5, cy, 5.6), 0.14, "iron", root)
			for n, (x, y) in enumerate(((-2.0, 0.9), (-1.45, 1.75))):
				cylinder(f"Cannon_oil{n}", 0.34, 0.34, 0.8, 10, (x, y, DECK + 0.4), "ash_dark", root)
				for z in (0.15, 0.65):
					cylinder(f"Cannon_oil{n}_hoop{z}", 0.36, 0.36, 0.06, 10, (x, y, DECK + z), "iron", root)
	with Variant(("heavy",)) as on:
		if on:
			leg_bands("Cannon_heavy", at, (2.2, 5.0, 7.2), root)
			for n in range(6):
				a = math.radians(205.0 + n * 26.0)
				sphere(f"Cannon_sandbag{n}", 0.4, (math.cos(a) * 2.45, math.sin(a) * 2.45, DECK + 0.3), "canvas", root, squash=(1.2, 0.8, 0.6))
	with Variant(("lofty",)) as on:
		if on:
			# A crow's nest high above the deck: this gun is meant for high ground.
			mx, my = 2.15, 1.95  # outside the railing, on the deck rim
			beam("Cannon_lookout_mast", (mx, my, DECK), (mx, my, DECK + 9.6), 0.18, "ash", root)
			for k, (dx, dy) in enumerate(((-1.2, 0.0), (0.0, -1.2))):
				beam(f"Cannon_lookout_stay{k}", (mx, my, DECK + 6.5), (mx + dx, my + dy, DECK + 0.1), 0.08, "rope", root)
			cylinder("Cannon_lookout_nest", 0.8, 0.85, 0.25, 8, (mx, my, DECK + 7.6), "ash", root)
			railing("Cannon_lookout_rail", DECK + 7.72, 0.78, 6, 0.6, root, width=0.1, cx=mx, cy=my)
			flag("Cannon_lookout_streamer", (mx, my, DECK + 9.5), 3.2, 0.5, root, direction=(-1.0, -0.3, 0.0))
	with Variant(("quake",)) as on:
		if on:
			# Broad stone plinths under every leg, and a bronze gong on deck.
			for n, (sx, sy) in enumerate(corners):
				box(f"Cannon_plinth{n}", (2.2, 2.2, 0.55), (sx * 2.7, sy * 2.7, 0.27), "whitewash", root, bevel=0.12)
			# A dry-stone wall between the legs: the tower is built to take the shock.
			for face, (dx, dy) in enumerate(((0, -1), (1, 0), (0, 1), (-1, 0))):
				tangent = Vector((-dy, dx, 0.0))
				for course, (z, h, spots) in enumerate(((0.36, 0.72, (-1.3, 0.0, 1.3)), (0.98, 0.52, (-0.65, 0.65)))):
					for k, s in enumerate(spots):
						if dy == 1 and abs(s) < 0.9:
							continue  # the ladder comes down here
						size = (0.8, 1.24, h) if dx else (1.24, 0.8, h)
						box(f"Cannon_wall{face}_{course}_{k}", size, Vector((dx * 3.0, dy * 3.0, z)) + tangent * s, "stone", root,
							Euler((0.0, 0.0, rng.uniform(-0.06, 0.06))), bevel=0.1)
			# The gong frame stays below the barrel so the gun can turn over it.
			for side in (-1.0, 1.0):
				beam(f"Cannon_gong_post{int(side)}", (side * 0.95, 2.35, DECK), (side * 0.95, 2.35, DECK + 1.85), 0.18, "ash", root)
			beam("Cannon_gong_bar", (-1.1, 2.35, DECK + 1.76), (1.1, 2.35, DECK + 1.76), 0.16, "ash", root)
			cylinder("Cannon_gong", 0.68, 0.68, 0.1, 20, (0.0, 2.35, DECK + 0.95), "bronze", root, axis=(0.0, 1.0, 0.0))
			sphere("Cannon_gong_boss", 0.2, (0.0, 2.29, DECK + 0.95), "bronze", root, squash=(1.0, 0.6, 1.0))
			for side in (-0.35, 0.35):
				beam(f"Cannon_gong_cord{side}", (side, 2.35, DECK + 1.7), (side * 0.8, 2.35, DECK + 1.58), 0.04, "rope", root)

	yaw = Node("Cannon_Yaw", (0.0, 0.0, DECK), root)
	cylinder("Cannon_turntable", 1.55, 1.45, 0.3, 16, (0.0, 0.0, DECK + 0.15), "ash_dark", yaw)
	cylinder("Cannon_turnring", 1.6, 1.6, 0.08, 16, (0.0, 0.0, DECK + 0.3), "iron", yaw)
	rise = PIVOT - DECK
	for side in (-1.0, 1.0):
		box(f"Cannon_cheek{int(side)}", (0.3, 2.6, 1.0), (side * 0.85, 0.5, DECK + 0.8), "ash", yaw)
		box(f"Cannon_upright{int(side)}", (0.3, 0.75, rise - 1.0), (side * 0.85, 0.0, DECK + 1.3 + (rise - 1.0) * 0.5 - 0.15), "ash", yaw)
		box(f"Cannon_cheek_cap{int(side)}", (0.36, 0.5, 0.26), (side * 0.85, 0.0, PIVOT - 0.12), "iron", yaw, bevel=0.04)
		cylinder(f"Cannon_wheel{int(side)}", 0.6, 0.6, 0.18, 12, (side * 1.08, 0.55, DECK + 0.62), "ash_dark", yaw, axis=(1.0, 0.0, 0.0))
		with Variant(("heavy",)) as on:
			if on:
				for y in (-0.2, 0.9, 1.6):
					box(f"Cannon_cheek_strap{int(side)}_{y}", (0.36, 0.16, 1.06), (side * 0.85, y, DECK + 0.8), "iron", yaw, bevel=0.02)

	pitch = Node("Cannon_Pitch", (0.0, 0.0, PIVOT), yaw)
	p = Vector((0.0, 0.0, PIVOT))
	F = FORWARD
	cylinder("Cannon_trunnion", 0.18, 0.18, 2.0, 10, p, "iron", pitch, axis=(1.0, 0.0, 0.0))
	with Variant(unless=("scatter", "heavy")) as on:
		if on:
			cylinder("Cannon_barrel", 0.52, 0.34, 5.6, 16, p + F * 1.6, "iron", pitch, axis=F)
			cylinder("Cannon_breech", 0.6, 0.54, 0.7, 16, p - F * 1.25, "iron", pitch, axis=F)
			sphere("Cannon_knob", 0.24, p - F * 1.8, "iron", pitch)
			for k, (t, r) in enumerate(((-0.75, 0.6), (1.2, 0.5), (2.6, 0.45))):
				cylinder(f"Cannon_ring{k}", r, r, 0.16, 16, p + F * t, "iron", pitch, axis=F)
			cylinder("Cannon_band0", 0.57, 0.56, 0.24, 16, p + F * 0.35, "sky", pitch, axis=F)
			cylinder("Cannon_mouth", 0.38, 0.5, 0.5, 16, p + F * 4.35, "iron", pitch, axis=F)
			Node("Cannon_Muzzle", p + F * 4.6, pitch)
	with Variant(("scatter",), ("fan",)) as on:
		if on:
			# Short barrel with a wide bell mouth: it sprays shot.
			cylinder("Cannon_scatter_barrel", 0.56, 0.48, 3.0, 16, p + F * 0.5, "iron", pitch, axis=F)
			cylinder("Cannon_scatter_breech", 0.62, 0.56, 0.6, 16, p - F * 1.2, "iron", pitch, axis=F)
			sphere("Cannon_scatter_knob", 0.24, p - F * 1.7, "iron", pitch)
			cylinder("Cannon_scatter_band", 0.6, 0.6, 0.24, 16, p + F * 0.2, "sky", pitch, axis=F)
			cylinder("Cannon_scatter_bell", 0.48, 1.05, 1.1, 18, p + F * 2.5, "iron", pitch, axis=F)
			cylinder("Cannon_scatter_bore", 0.78, 0.78, 0.04, 18, p + F * 3.13, "soot", pitch, axis=F)
			cylinder("Cannon_scatter_lip", 1.1, 1.1, 0.14, 18, p + F * 3.05, "iron", pitch, axis=F)
			Node("Cannon_Muzzle_scatter", p + F * 3.15, pitch)
			with Variant(("blaze",)) as on2:
				if on2:
					# A fire box under the breech and an ember glow in the bell.
					cylinder("Cannon_blaze_glow", 0.8, 0.8, 0.04, 18, p + F * 3.16, "ember", pitch, axis=F)
					box("Cannon_blaze_firebox", (0.95, 1.1, 0.7), p - F * 0.6 + Vector((0.0, 0.0, -0.85)), "iron", pitch, bevel=0.05)
					box("Cannon_blaze_grate", (0.75, 0.9, 0.08), p - F * 0.6 + Vector((0.0, 0.0, -0.47)), "ember", pitch, bevel=0.0)
					cylinder("Cannon_blaze_flue", 0.12, 0.1, 1.5, 8, p - F * 0.9 + Vector((0.62, 0.0, -0.1)), "iron", pitch)
					cylinder("Cannon_blaze_flue_cap", 0.2, 0.14, 0.2, 8, p - F * 0.9 + Vector((0.62, 0.0, 0.7)), "iron", pitch)
	with Variant(("fan",)) as on:
		if on:
			# Three barrels splayed like the ribs of a fan, under a fan-shaped crest.
			box("Cannon_fan_breech", (1.9, 1.0, 0.95), p - F * 0.6, "iron", pitch, bevel=0.08)
			box("Cannon_fan_band", (1.96, 0.26, 1.0), p - F * 0.6, "sky", pitch, bevel=0.04)
			for k, ang in enumerate((-0.3, 0.0, 0.3)):
				d = Matrix.Rotation(ang, 3, "Z") @ F
				cylinder(f"Cannon_fan_barrel{k}", 0.36, 0.28, 3.6, 14, p + d * 1.4, "iron", pitch, axis=d)
				cylinder(f"Cannon_fan_mouth{k}", 0.28, 0.42, 0.42, 14, p + d * 3.35, "iron", pitch, axis=d)
			apex = p - F * 0.5 + Vector((0.0, 0.0, 0.7))
			ribs = 7
			spread = 2.0
			outs = []
			for k in range(ribs + 1):
				ang = -spread * 0.5 + spread * k / ribs
				d = Matrix.Rotation(ang, 3, "Z") @ F
				outs.append(apex + d * 2.3 + Vector((0.0, 0.0, 1.9)))
				beam(f"Cannon_fan_rib{k}", apex, outs[-1], 0.06, "ash_dark", pitch)
			for k in range(ribs):
				left = apex.lerp(outs[k], 0.12)
				right = apex.lerp(outs[k + 1], 0.12)
				canvas(f"Cannon_fan_leaf{k}", (left, right, outs[k + 1], outs[k]), pitch, sag=0.04,
					outward=Vector((0.0, 0.3, 1.0)), stripes=((0.0, 1.0),) if k % 2 else ((0.8, 1.0),), cols=1, rows=2)
			Node("Cannon_Muzzle_fan", p + F * 3.55, pitch)
	with Variant(("heavy",)) as on:
		if on:
			# A long heavy barrel bound with iron rings.
			cylinder("Cannon_heavy_barrel", 0.76, 0.52, 6.6, 16, p + F * 2.0, "iron", pitch, axis=F)
			cylinder("Cannon_heavy_breech", 0.84, 0.78, 0.8, 16, p - F * 1.35, "iron", pitch, axis=F)
			sphere("Cannon_heavy_knob", 0.34, p - F * 1.95, "iron", pitch)
			for k, (t, r) in enumerate(((-0.9, 0.86), (0.7, 0.78), (2.1, 0.72), (3.5, 0.66), (4.7, 0.61))):
				cylinder(f"Cannon_heavy_ring{k}", r, r, 0.2, 16, p + F * t, "iron", pitch, axis=F)
			cylinder("Cannon_heavy_band", 0.82, 0.81, 0.26, 16, p + F * -0.2, "sky", pitch, axis=F)
			with Variant(unless=("quake",)) as on2:
				if on2:
					cylinder("Cannon_heavy_mouth", 0.52, 0.68, 0.55, 16, p + F * 5.3, "iron", pitch, axis=F)
			with Variant(("lofty",)) as on2:
				if on2:
					cylinder("Cannon_lofty_scope", 0.15, 0.15, 2.8, 10, p + F * 1.0 + Vector((0.0, 0.0, 1.1)), "iron", pitch, axis=F)
					cylinder("Cannon_lofty_eye", 0.22, 0.15, 0.35, 10, p + F * -0.55 + Vector((0.0, 0.0, 1.1)), "iron", pitch, axis=F)
					cylinder("Cannon_lofty_lens", 0.2, 0.2, 0.2, 10, p + F * 2.45 + Vector((0.0, 0.0, 1.1)), "brass", pitch, axis=F)
					for t in (0.2, 1.8):
						box(f"Cannon_lofty_mount{t}", (0.1, 0.16, 0.4), p + F * t + Vector((0.0, 0.0, 0.88)), "iron", pitch, bevel=0.0)
			with Variant(("quake",)) as on2:
				if on2:
					cylinder("Cannon_quake_ram", 1.08, 1.02, 0.85, 12, p + F * 5.2, "stone", pitch, axis=F)
					for k in range(6):
						a = k * math.tau / 6
						off = Vector((math.cos(a), 0.0, math.sin(a))) * 1.05
						box(f"Cannon_quake_stud{k}", (0.22, 0.5, 0.22), p + F * 5.2 + off, "iron", pitch, bevel=0.03)
					box("Cannon_quake_weight", (1.3, 0.8, 0.9), p - F * 2.1 + Vector((0.0, 0.0, -0.1)), "stone", pitch, bevel=0.1)
			Node("Cannon_Muzzle_heavy", p + F * 5.65, pitch)
	star_ranks("Cannon", pitch, p + F * 0.7, 0.8, F, pole_top, root)


def build_catapult(root):
	"""A squat trestle platform with a throwing arm. Deck at 4.72 m, arm axle at 7.6 m.
	Lines: boulder (doubled arm, big cup and boulder) -> meteor (glowing star stone, star-vane mast)
	                                                  -> rubble (gravel heap in a net, stone crusher, rubble at the feet)
	       volley (light banded arm, treadwheel, stone rack) -> firepot (clay fire pots, brazier)
	                                                         -> farthrow (long arm with sling, outriggers)"""
	DECK, PIVOT = 4.72, 7.6
	for n in range(6):
		a = n * math.tau / 6 + math.pi / 6
		whitewash_footing(f"Catapult_foot{n}", (math.cos(a) * 3.3, math.sin(a) * 3.3, 0.0), root, size=1.3, height=0.9)
		top = Vector((math.cos(a) * 3.0, math.sin(a) * 3.0, DECK - 0.4))
		beam(f"Catapult_leg{n}", (math.cos(a) * 3.3, math.sin(a) * 3.3, 0.8), top, 0.4, "ash", root)
		b = (n + 1) * math.tau / 6 + math.pi / 6
		nxt = Vector((math.cos(b) * 3.3, math.sin(b) * 3.3, 1.2))
		beam(f"Catapult_x{n}a", (math.cos(a) * 3.3, math.sin(a) * 3.3, 1.2), Vector((math.cos(b) * 3.0, math.sin(b) * 3.0, DECK - 0.5)), 0.2, "ash_dark", root)
		beam(f"Catapult_x{n}b", nxt, top + Vector((0.0, 0.0, -0.1)), 0.2, "ash_dark", root)
	deck("Catapult", DECK, 3.75, 0.45, root, sides=6)
	for n in range(6):
		a = n * math.tau / 6
		b = (n + 1) * math.tau / 6
		pa = Vector((math.cos(a) * 3.85, math.sin(a) * 3.85, DECK - 0.3))
		pb = Vector((math.cos(b) * 3.85, math.sin(b) * 3.85, DECK - 0.3))
		mid = (pa + pb) * 0.5
		out = Vector((mid.x, mid.y, 0.0)).normalized()
		canvas(f"Catapult_valance{n}", (pa - Vector((0, 0, 1.4)), pb - Vector((0, 0, 1.4)), pb, pa), root, sag=0.25, outward=out,
			stripes=((0.12, 0.3),), rows=4, scallop=0.9)
		beam(f"Catapult_tie{n}", pa + out * 0.05, pa + out * 0.05 + Vector((0.0, 0.0, -0.6)), 0.06, "rope", root)
	for k, y in enumerate((-3.97, 3.97)):
		out = Vector((0.0, -1.0 if y < 0 else 1.0, 0.0))
		top, bottom = DECK - 0.35, DECK - 2.9
		canvas(f"Catapult_banner{k}", ((-0.6, y, bottom), (0.6, y, bottom), (0.6, y, top), (-0.6, y, top)), root,
			sag=0.05, outward=out, stripes=((0.0, 1.0),), cols=2, rows=4)
		mid = (top + bottom) * 0.5 + 0.1
		box(f"Catapult_banner{k}_mark", (0.5, 0.02, 0.5), (0.0, y + out.y * 0.08, mid), "canvas", root,
			Euler((0.0, math.pi * 0.25, 0.0)), bevel=0.0)
		for b, dz in enumerate((-0.75, 0.75)):
			box(f"Catapult_banner{k}_band{b}", (1.05, 0.02, 0.1), (0.0, y + out.y * 0.08, mid + dz), "canvas", root, bevel=0.0)
		beam(f"Catapult_banner{k}_rod", (-0.75, y, top + 0.05), (0.75, y, top + 0.05), 0.08, "ash_dark", root)
	ladder("Catapult_ladder", (2.4, 4.4, 0.0), (1.9, 3.3, DECK), 0.8, root)
	railing("Catapult_rail", DECK, 3.55, 6, 0.8, root)
	with Variant(unless=("boulder", "volley")) as on:
		if on:
			for n in range(3):
				sphere(f"Catapult_ammo{n}", 0.42, (-2.1 + n * 0.5, 2.2 - (n % 2) * 0.4, DECK + 0.35), "stone", root, squash=(1.0, 0.9, 0.8))
	sphere("Catapult_sack0", 0.36, (2.3, 1.2, DECK + 0.32), "canvas", root, squash=(1.0, 0.9, 0.9))
	sphere("Catapult_sack1", 0.32, (2.6, 0.6, DECK + 0.28), "canvas", root, squash=(1.0, 0.9, 0.9))
	pole_top = Vector((-2.6, -1.5, DECK + 2.9))
	beam("Catapult_flagpole", (-2.6, -1.5, DECK), (-2.6, -1.5, DECK + 3.0), 0.12, "ash", root)
	flag("Catapult_flag", pole_top, 1.3, 0.65, root, direction=(1.0, 0.3, 0.0))
	with Variant(("boulder",)) as on:
		if on:
			for n, (x, y) in enumerate(((-2.2, 2.0), (-1.4, 2.6), (-2.6, 1.0))):
				sphere(f"Catapult_boulder_pile{n}", 0.62, (x, y, DECK + 0.5), "stone", root, squash=(1.0, 0.9, 0.8))
			# A ring of ballast stones between the legs holds the platform down under the heavier throw.
			for n in range(6):
				a = n * math.tau / 6
				centre = Vector((math.cos(a) * 2.75, math.sin(a) * 2.75, 0.0))
				for course, (z, h, length) in enumerate(((0.33, 0.66, 1.75), (0.9, 0.48, 1.2))):
					box(f"Catapult_ballast{n}_{course}", (length, 0.8, h), centre + Vector((0.0, 0.0, z)), "stone", root,
						Euler((0.0, 0.0, a + math.pi * 0.5 + rng.uniform(-0.06, 0.06))), bevel=0.1)
	with Variant(("meteor",)) as on:
		if on:
			# A tall mast topped with a brass star vane: build it on the highest hill.
			mx, my = 2.4, -1.7
			beam("Catapult_star_mast", (mx, my, DECK), (mx, my, DECK + 8.0), 0.16, "ash", root)
			for k in range(4):
				box(f"Catapult_star_point{k}", (1.5 if k % 2 == 0 else 1.0, 0.1, 0.22), (mx, my, DECK + 8.3), "brass", root,
					Euler((0.0, k * math.pi * 0.25, 0.0)), bevel=0.02)
			flag("Catapult_star_streamer", (mx, my, DECK + 7.8), 2.8, 0.45, root, direction=(1.0, 0.2, 0.0))
	with Variant(("rubble",)) as on:
		if on:
			# A crusher hopper on deck and broken stone heaped round the feet.
			hx, hy = -2.0, 1.6
			for k, (dx, dy) in enumerate(((-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5))):
				beam(f"Catapult_hopper_leg{k}", (hx + dx, hy + dy, DECK), (hx + dx * 0.8, hy + dy * 0.8, DECK + 1.3), 0.12, "ash_dark", root)
			cylinder("Catapult_hopper", 0.35, 1.0, 1.1, 8, (hx, hy, DECK + 1.75), "ash", root)
			for k in range(7):
				sphere(f"Catapult_gravel{k}", rng.uniform(0.18, 0.28), (hx + rng.uniform(-0.6, 0.6), hy + rng.uniform(-0.6, 0.6), DECK + 0.15),
					"stone", root, squash=(1.0, 1.0, 0.7))
			for n in range(6):
				a = n * math.tau / 6 + math.pi / 6
				for k in range(4):
					r = 3.3 + rng.uniform(0.6, 1.1)
					b = a + rng.uniform(-0.35, 0.35)
					sphere(f"Catapult_rubble{n}_{k}", rng.uniform(0.2, 0.38), (math.cos(b) * r, math.sin(b) * r, 0.12), "stone", root,
						squash=(1.0, 1.0, 0.65))
	with Variant(("firepot",)) as on:
		if on:
			for n in range(4):
				pos = Vector((-2.4 + (n % 2) * 0.6, 1.4 + (n // 2) * 0.6, DECK + 0.38))
				sphere(f"Catapult_pot{n}", 0.32, pos, "clay", root, squash=(1.0, 1.0, 1.15))
				cylinder(f"Catapult_pot{n}_neck", 0.12, 0.14, 0.18, 8, pos + Vector((0.0, 0.0, 0.42)), "clay", root)
			cylinder("Catapult_brazier", 0.45, 0.3, 0.5, 8, (2.2, -1.2, DECK + 0.6), "iron", root)
			sphere("Catapult_brazier_glow", 0.36, (2.2, -1.2, DECK + 0.85), "ember", root, squash=(1.0, 1.0, 0.5))
			for k in range(3):
				a = k * math.tau / 3
				beam(f"Catapult_brazier_leg{k}", (2.2 + math.cos(a) * 0.4, -1.2 + math.sin(a) * 0.4, DECK), (2.2, -1.2, DECK + 0.4), 0.06, "iron", root)
			# A beehive kiln under the platform fires the pots; its door glows between the legs.
			sphere("Catapult_kiln", 1.65, (0.0, 0.0, 0.15), "clay", root, squash=(1.0, 1.0, 0.95), detail=2)
			box("Catapult_kiln_door", (0.9, 0.1, 0.8), (0.0, -1.6, 0.55), "ember", root, bevel=0.0)
			box("Catapult_kiln_arch", (1.3, 0.3, 0.24), (0.0, -1.6, 1.08), "stone", root, bevel=0.05)
			cylinder("Catapult_kiln_flue", 0.32, 0.26, 1.7, 8, (0.55, 0.45, 2.2), "clay", root)
			cylinder("Catapult_kiln_flue_cap", 0.38, 0.3, 0.2, 8, (0.55, 0.45, 3.1), "soot", root)
			for k, (x, y) in enumerate(((-1.9, -1.2), (-1.6, -1.75))):
				beam(f"Catapult_kiln_log{k}", (x, y, 0.2), (x + 0.9, y - 0.4, 0.2), 0.28, "ash_dark", root)
	with Variant(("farthrow",)) as on:
		if on:
			# Outriggers brace the platform for the long arm, buttressing three of the legs.
			for n, deg in enumerate((30.0, 150.0, 210.0, 330.0)):
				a = math.radians(deg)
				foot = Vector((math.cos(a) * 5.3, math.sin(a) * 5.3, 0.0))
				whitewash_footing(f"Catapult_outrigger_foot{n}", foot, root, size=1.0, height=0.7)
				beam(f"Catapult_outrigger{n}", foot + Vector((0.0, 0.0, 0.6)), (math.cos(a) * 3.15, math.sin(a) * 3.15, DECK - 2.0), 0.3, "ash", root)

	yaw = Node("Catapult_Yaw", (0.0, 0.0, DECK), root)
	box("Catapult_bed", (3.0, 4.2, 0.3), (0.0, 0.0, DECK + 0.15), "ash_dark", yaw)
	rise = PIVOT - DECK
	for side in (-1.0, 1.0):
		x = side * 1.15
		for lean in (-1.0, 1.0):
			beam(f"Catapult_aframe{int(side)}{int(lean)}", (x, lean * 1.5, DECK + 0.3), (x, 0.0, PIVOT + 0.15), 0.3, "ash", yaw)
		beam(f"Catapult_aframe_tie{int(side)}", (x, -0.85, DECK + 1.3), (x, 0.85, DECK + 1.3), 0.2, "ash_dark", yaw)
	beam("Catapult_axle", (-1.45, 0.0, PIVOT), (1.45, 0.0, PIVOT), 0.24, "iron", yaw)
	with Variant(unless=("volley",)) as on:
		if on:
			cylinder("Catapult_winch", 0.38, 0.38, 2.0, 12, (0.0, 1.55, DECK + 0.75), "ash", yaw, axis=(1.0, 0.0, 0.0))
			cylinder("Catapult_winch_rope", 0.42, 0.42, 1.0, 12, (0.0, 1.55, DECK + 0.75), "rope", yaw, axis=(1.0, 0.0, 0.0))
			for side in (-1.0, 1.0):
				beam(f"Catapult_winch_post{int(side)}", (side * 1.05, 1.55, DECK + 0.3), (side * 1.05, 1.55, DECK + 1.15), 0.22, "ash_dark", yaw)
	with Variant(("volley",)) as on:
		if on:
			# A treadwheel winds the arm back down fast; a rack keeps stones ready.
			R = 1.3
			c = Vector((0.0, 1.9, DECK + 1.55))
			segments = 14
			for k in range(segments):
				a0, a1 = k * math.tau / segments, (k + 1) * math.tau / segments
				for x in (-0.5, 0.5):
					beam(f"Catapult_wheel_rim{k}_{x}", c + Vector((x, math.cos(a0) * R, math.sin(a0) * R)),
						c + Vector((x, math.cos(a1) * R, math.sin(a1) * R)), 0.14, "ash", yaw)
				beam(f"Catapult_wheel_tread{k}", c + Vector((-0.5, math.cos(a0) * R, math.sin(a0) * R)),
					c + Vector((0.5, math.cos(a0) * R, math.sin(a0) * R)), 0.08, "ash_dark", yaw)
			for k in range(4):
				a = k * math.pi / 4
				for x in (-0.5, 0.5):
					beam(f"Catapult_wheel_spoke{k}_{x}", c + Vector((x, math.cos(a) * (R - 0.05), math.sin(a) * (R - 0.05))),
						c + Vector((x, -math.cos(a) * (R - 0.05), -math.sin(a) * (R - 0.05))), 0.1, "ash", yaw)
			cylinder("Catapult_wheel_hub", 0.2, 0.2, 1.4, 8, c, "iron", yaw, axis=(1.0, 0.0, 0.0))
			for side in (-1.0, 1.0):
				beam(f"Catapult_wheel_post{int(side)}", (side * 0.75, 1.9, DECK + 0.3), (side * 0.75, 1.9, DECK + 1.65), 0.2, "ash_dark", yaw)
			beam("Catapult_rack", (1.55, -1.4, DECK + 0.6), (1.55, 1.0, DECK + 0.6), 0.16, "ash_dark", yaw)
			for y in (-1.3, 0.9):
				beam(f"Catapult_rack_leg{y}", (1.55, y, DECK + 0.3), (1.55, y, DECK + 0.6), 0.12, "ash_dark", yaw)
			with Variant(unless=("firepot",)) as on2:
				if on2:
					for k in range(4):
						sphere(f"Catapult_rack_stone{k}", 0.27, (1.55, -1.1 + k * 0.62, DECK + 0.88), "stone", yaw)

	pitch = Node("Catapult_Pitch", (0.0, 0.0, PIVOT), yaw)
	p = Vector((0.0, 0.0, PIVOT))
	F = FORWARD
	with Variant(unless=("boulder", "volley")) as on:
		if on:
			beam("Catapult_arm", p - F * 2.4, p + F * 6.0, 0.36, "ash", pitch)
			for t in (-1.6, 1.0, 3.4):
				box(f"Catapult_arm_band{t}", (0.46, 0.2, 0.46), p + F * t, "rope", pitch, bevel=0.03)
			beam("Catapult_hanger", p - F * 2.2, p - F * 2.2 + Vector((0.0, 0.0, -0.9)), 0.14, "iron", pitch)
			box("Catapult_counterweight", (1.3, 1.1, 1.0), p - F * 2.2 + Vector((0.0, 0.0, -1.4)), "ash_dark", pitch)
			for n in range(3):
				sphere(f"Catapult_cw_stone{n}", 0.3, p - F * (2.0 + n * 0.25) + Vector((-0.3 + n * 0.3, 0.0, -0.85)), "stone", pitch)
			cylinder("Catapult_cup", 0.55, 0.85, 0.5, 12, p + F * 6.1 + Vector((0.0, 0.0, 0.2)), "ash_dark", pitch)
			sphere("Catapult_stone", 0.5, p + F * 6.1 + Vector((0.0, 0.0, 0.62)), "stone", pitch, squash=(1.0, 0.9, 0.8))
			Node("Catapult_Muzzle", p + F * 6.1 + Vector((0.0, 0.0, 0.6)), pitch)
	with Variant(("boulder",)) as on:
		if on:
			# Two timbers bolted together, a heavier counterweight and a deep cup.
			for x in (-0.24, 0.24):
				beam(f"Catapult_boulder_arm{x}", p - F * 2.6 + Vector((x, 0.0, 0.0)), p + F * 6.2 + Vector((x * 0.6, 0.0, 0.0)), 0.32, "ash", pitch)
			for t in (-1.8, 0.9, 3.2, 5.0):
				box(f"Catapult_boulder_band{t}", (0.95, 0.18, 0.44), p + F * t, "iron", pitch, bevel=0.03)
			beam("Catapult_boulder_hanger", p - F * 2.4, p - F * 2.4 + Vector((0.0, 0.0, -0.9)), 0.18, "iron", pitch)
			box("Catapult_boulder_counterweight", (1.9, 1.5, 1.4), p - F * 2.4 + Vector((0.0, 0.0, -1.6)), "ash_dark", pitch)
			for n in range(4):
				sphere(f"Catapult_boulder_cw{n}", 0.36, p - F * (2.1 + (n % 2) * 0.5) + Vector((-0.4 + (n // 2) * 0.8, 0.0, -0.85)), "stone", pitch)
			cylinder("Catapult_boulder_cup", 0.8, 1.25, 0.6, 12, p + F * 6.3 + Vector((0.0, 0.0, 0.25)), "ash_dark", pitch)
			with Variant(unless=("meteor", "rubble")) as on2:
				if on2:
					sphere("Catapult_boulder", 0.85, p + F * 6.3 + Vector((0.0, 0.0, 0.9)), "stone", pitch, squash=(1.0, 0.92, 0.82))
			with Variant(("meteor",)) as on2:
				if on2:
					sphere("Catapult_starstone", 0.82, p + F * 6.3 + Vector((0.0, 0.0, 0.95)), "starstone", pitch, detail=0)
					for k in range(3):
						a = k * math.tau / 3
						box(f"Catapult_starstone_clamp{k}", (0.12, 0.12, 0.7), p + F * 6.3 + Vector((math.cos(a) * 0.75, math.sin(a) * 0.75, 0.7)),
							"brass", pitch, bevel=0.0)
			with Variant(("rubble",)) as on2:
				if on2:
					for k in range(9):
						off = Vector((rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6), 0.55 + rng.uniform(0.0, 0.5)))
						sphere(f"Catapult_rubble_load{k}", rng.uniform(0.22, 0.34), p + F * 6.3 + off, "stone", pitch, squash=(1.0, 1.0, 0.75))
					for k in range(4):
						a = k * math.pi / 4
						d = Vector((math.cos(a), math.sin(a), 0.0)) * 1.15
						beam(f"Catapult_net{k}", p + F * 6.3 + d + Vector((0.0, 0.0, 0.5)), p + F * 6.3 - d + Vector((0.0, 0.0, 0.5)) + Vector((0.0, 0.0, 0.0)),
							0.04, "rope", pitch)
			Node("Catapult_Muzzle_boulder", p + F * 6.3 + Vector((0.0, 0.0, 0.9)), pitch)
	with Variant(("volley",)) as on:
		if on:
			# A lighter arm with iron bands: quicker to swing and wind back.
			beam("Catapult_volley_arm", p - F * 2.0, p + F * 6.0, 0.28, "ash", pitch)
			for t in (-1.4, 0.8, 2.8, 4.6):
				box(f"Catapult_volley_band{t}", (0.38, 0.16, 0.38), p + F * t, "iron", pitch, bevel=0.02)
			beam("Catapult_volley_hanger", p - F * 1.85, p - F * 1.85 + Vector((0.0, 0.0, -0.8)), 0.12, "iron", pitch)
			box("Catapult_volley_counterweight", (1.1, 0.9, 0.9), p - F * 1.85 + Vector((0.0, 0.0, -1.25)), "ash_dark", pitch)
			for z in (-0.95, -1.55):
				box(f"Catapult_volley_cw_band{z}", (1.16, 0.96, 0.1), p - F * 1.85 + Vector((0.0, 0.0, z)), "iron", pitch, bevel=0.0)
			with Variant(unless=("farthrow",)) as on2:
				if on2:
					cylinder("Catapult_volley_cup", 0.5, 0.75, 0.45, 12, p + F * 6.1 + Vector((0.0, 0.0, 0.18)), "ash_dark", pitch)
					with Variant(unless=("firepot",)) as on3:
						if on3:
							sphere("Catapult_volley_stone", 0.42, p + F * 6.1 + Vector((0.0, 0.0, 0.55)), "stone", pitch, squash=(1.0, 0.9, 0.8))
					with Variant(("firepot",)) as on3:
						if on3:
							sphere("Catapult_firepot", 0.42, p + F * 6.1 + Vector((0.0, 0.0, 0.7)), "clay", pitch, squash=(1.0, 1.0, 1.15))
							cylinder("Catapult_firepot_neck", 0.15, 0.17, 0.2, 8, p + F * 6.1 + Vector((0.0, 0.0, 1.22)), "clay", pitch)
							sphere("Catapult_firepot_flame", 0.2, p + F * 6.1 + Vector((0.0, 0.0, 1.4)), "ember", pitch, squash=(1.0, 1.0, 1.5))
					Node("Catapult_Muzzle_volley", p + F * 6.1 + Vector((0.0, 0.0, 0.6)), pitch)
			with Variant(("farthrow",)) as on2:
				if on2:
					# The arm runs on to 8.6 m and throws from a rope sling.
					beam("Catapult_far_arm", p + F * 5.6, p + F * 8.6, 0.22, "ash", pitch)
					box("Catapult_far_splice", (0.34, 0.9, 0.34), p + F * 5.9, "iron", pitch, bevel=0.02)
					tip = p + F * 8.6
					pouch = tip + Vector((0.0, 0.0, -1.5))
					for x in (-0.18, 0.18):
						beam(f"Catapult_sling{x}", tip, pouch + Vector((x, 0.0, 0.2)), 0.04, "rope", pitch)
					sphere("Catapult_sling_pouch", 0.36, pouch, "canvas", pitch, squash=(1.0, 1.0, 0.7))
					sphere("Catapult_sling_stone", 0.3, pouch + Vector((0.0, 0.0, 0.2)), "stone", pitch)
					Node("Catapult_Muzzle_farthrow", pouch, pitch)
	star_ranks("Catapult", pitch, p + F * 0.2, 0.55, F, pole_top, root)


def build_sniper(root):
	"""A tall slim lookout. Deck at 11.22 m, gun pivot at 13.6 m.
	Lines: quick (drum magazine; the windmill grows to six blades and drives the loader by rope)
	           -> twin (two barrels, two drums, eight big blades)
	           -> eagle (long scope with sunshade, crow's nest at the top of the mast)
	       heavyshot (thick barrel, slotted brake, gun shield, iron straps)
	           -> pin (harpoon head and rope reel)
	           -> burst (flared muzzle, crate of shells)"""
	DECK, PIVOT = 11.22, 13.6
	for n, (sx, sy) in enumerate([(1, 1), (-1, 1), (-1, -1), (1, -1)]):
		whitewash_footing(f"Sniper_foot{n}", (sx * 2.1, sy * 2.1, 0.0), root, size=1.2, height=1.0)
	at = frame_legs("Sniper_frame", 2.1, 1.15, [1.0, 4.4, 7.8, DECK - 0.32], root, leg_width=0.3)
	with Variant(unless=("heavyshot",)) as on:
		if on:
			canvas("Sniper_sail0", (at(1, -1, 2.2) + Vector((0, -0.25, 0)), at(-1, -1, 2.2) + Vector((0, -0.25, 0)),
				at(-1, -1, 9.6) + Vector((0, -0.25, 0)), at(1, -1, 7.2) + Vector((0, -0.25, 0))), root, sag=0.5, outward=(0.0, -1.0, 0.0),
				stripes=((0.3, 0.4), (0.75, 0.84)))
	with Variant(("heavyshot",)) as on:
		if on:
			# Plank armour replaces the front sail, with a painted band in the line's colour.
			boards = 9
			for k in range(boards):
				t = (k + 0.5) / boards
				bottom = at(1, -1, 2.0).lerp(at(-1, -1, 2.0), t) + Vector((0.0, -0.3, 0.0))
				top = at(1, -1, 9.9).lerp(at(-1, -1, 9.9), t) + Vector((0.0, -0.3, 0.0))
				beam(f"Sniper_plank{k}", bottom, top, 0.38, "ash_dark" if k % 3 == 1 else "ash", root, depth=0.12)
			for k, z in enumerate((3.0, 6.2, 9.2)):
				beam(f"Sniper_plank_strap{k}", at(1, -1, z) + Vector((0.15, -0.4, 0.0)), at(-1, -1, z) + Vector((-0.15, -0.4, 0.0)),
					0.16, "iron", root)
			for k, z in enumerate((4.6, 7.7)):
				beam(f"Sniper_plank_band{k}", at(1, -1, z) + Vector((0.1, -0.38, 0.0)), at(-1, -1, z) + Vector((-0.1, -0.38, 0.0)),
					0.06, "sky", root, depth=1.1)
	canvas("Sniper_sail1", (at(1, 1, 5.0) + Vector((0.25, 0, 0)), at(1, -1, 3.0) + Vector((0.25, 0, 0)),
		at(1, -1, 9.0) + Vector((0.25, 0, 0)), at(1, 1, 10.2) + Vector((0.25, 0, 0))), root, sag=0.45, outward=(1.0, 0.0, 0.0),
		stripes=((0.5, 0.62),))
	deck("Sniper", DECK, 2.1, 0.32, root)
	railing("Sniper_rail", DECK, 1.95, 8, 0.95, root, gap=math.pi * 0.5)
	ladder("Sniper_ladder", (0.0, 2.6, 0.0), (0.0, 1.4, DECK), 0.7, root)
	hub = (-1.35, 0.0, 9.4)
	with Variant(unless=("quick",)) as on:
		if on:
			vanes("Sniper_Vanes", hub, (-1.0, 0.0, 0.0), 2.4, root)
	with Variant(("quick",), ("twin",)) as on:
		if on:
			vanes("Sniper_Vanes_quick", hub, (-1.0, 0.0, 0.0), 2.6, root, blades=6)
	with Variant(("twin",)) as on:
		if on:
			vanes("Sniper_Vanes_twin", hub, (-1.0, 0.0, 0.0), 3.1, root, blades=8)
			# A second, smaller windmill lower down: two rotors for two barrels.
			vanes("Sniper_Vanes_twin_low", (-1.75, 0.0, 4.4), (-1.0, 0.0, 0.0), 2.2, root)
	with Variant(("quick",)) as on:
		if on:
			# The windmill now drives the loader: a drive rope runs from its hub up to the deck.
			cylinder("Sniper_drive_pulley", 0.35, 0.35, 0.16, 12, (-1.25, 0.0, DECK - 0.15), "ash_dark", root, axis=(0.0, 1.0, 0.0))
			for z in (0.3, -0.3):
				beam(f"Sniper_drive_rope{z}", (-1.6, 0.0, 9.4 + z), (-1.25, 0.0, DECK - 0.15 + z * 1.1), 0.05, "rope", root)
	hanging_load("Sniper_hoist", at(1, 1, 9.8), at(1, 1, 9.8) + Vector((1.5, 0.6, 0.3)), 3.0, root, kind="crate")
	pole_top = Vector((-1.5, 1.5, DECK + 5.1))
	with Variant(unless=("eagle",)) as on:
		if on:
			beam("Sniper_mast", (-1.5, 1.5, DECK), (-1.5, 1.5, DECK + 5.2), 0.14, "ash", root)
			flag("Sniper_streamer", pole_top, 2.6, 0.45, root, direction=(1.0, -0.4, 0.0))
	with Variant(("eagle",)) as on:
		if on:
			# The mast grows a crow's nest with a spyglass on a stand.
			beam("Sniper_mast_eagle", (-1.5, 1.5, DECK), (-1.5, 1.5, DECK + 8.6), 0.16, "ash", root)
			cylinder("Sniper_nest", 0.75, 0.8, 0.24, 8, (-1.5, 1.5, DECK + 6.6), "ash", root)
			railing("Sniper_nest_rail", DECK + 6.72, 0.72, 6, 0.55, root, width=0.09, cx=-1.5, cy=1.5)
			cylinder("Sniper_nest_glass", 0.1, 0.14, 1.2, 8, (-1.5, 1.05, DECK + 7.5), "brass", root, axis=(0.3, -1.0, 0.25))
			flag("Sniper_streamer_eagle", (-1.5, 1.5, DECK + 8.5), 3.6, 0.5, root, direction=(1.0, -0.4, 0.0))
	with Variant(("heavyshot",)) as on:
		if on:
			leg_bands("Sniper_heavy", at, (2.4, 5.8, 9.2), root, width=0.46)
	with Variant(("burst",)) as on:
		if on:
			# Turned to lie along the rail, clear of the turntable.
			c = Vector((0.96, -0.96, DECK))
			tang = Vector((0.7071, 0.7071, 0.0))
			box("Sniper_shell_crate", (0.75, 0.45, 0.4), c + Vector((0.0, 0.0, 0.2)), "ash_dark", root, Euler((0.0, 0.0, math.pi * 0.25)))
			for k in range(4):
				pos = c + tang * ((k - 1.5) * 0.17) + Vector((0.0, 0.0, 0.57))
				cylinder(f"Sniper_shell{k}", 0.07, 0.07, 0.34, 8, pos, "brass", root)
				cylinder(f"Sniper_shell{k}_tip", 0.07, 0.02, 0.15, 8, pos + Vector((0.0, 0.0, 0.24)), "shell", root)
			# Powder kegs stacked at the foot of the tower, banded in the line's colour.
			for k, (x, y, z) in enumerate(((0.55, -3.3, 0.0), (1.35, -3.3, 0.0), (0.95, -3.3, 0.78), (0.95, -2.65, 0.0))):
				cylinder(f"Sniper_keg{k}", 0.36, 0.36, 0.76, 10, (x, y, z + 0.38), "ash_dark", root)
				cylinder(f"Sniper_keg{k}_band", 0.38, 0.38, 0.18, 10, (x, y, z + 0.38), "sky", root)
				for h in (0.1, 0.66):
					cylinder(f"Sniper_keg{k}_hoop{h}", 0.38, 0.38, 0.05, 10, (x, y, z + h), "iron", root)
	with Variant(("pin",)) as on:
		if on:
			cylinder("Sniper_spare_reel", 0.3, 0.3, 0.45, 10, (0.96, -0.96, DECK + 0.32), "rope", root, axis=(0.7071, 0.7071, 0.0))
			# A big line winch at the foot of the tower reels the harpoon back in.
			wy = -3.4
			for side in (-1.0, 1.0):
				box(f"Sniper_winch_post{int(side)}", (0.3, 0.55, 1.9), (side * 0.95, wy, 0.95), "ash", root)
				cylinder(f"Sniper_winch_crank{int(side)}", 0.1, 0.1, 0.5, 6, (side * 1.3, wy, 1.4), "iron", root, axis=(1.0, 0.0, 0.0))
			cylinder("Sniper_winch_drum", 0.72, 0.72, 1.5, 12, (0.0, wy, 1.4), "ash_dark", root, axis=(1.0, 0.0, 0.0))
			cylinder("Sniper_winch_line", 0.8, 0.8, 1.1, 12, (0.0, wy, 1.4), "rope", root, axis=(1.0, 0.0, 0.0))
			cylinder("Sniper_winch_band", 0.82, 0.82, 0.2, 12, (0.0, wy, 1.4), "sky", root, axis=(1.0, 0.0, 0.0))
			beam("Sniper_winch_rope", (0.0, wy + 0.4, 2.1), (0.0, -1.6, DECK - 0.1), 0.05, "rope", root)

	yaw = Node("Sniper_Yaw", (0.0, 0.0, DECK), root)
	cylinder("Sniper_turntable", 0.95, 0.9, 0.26, 14, (0.0, 0.0, DECK + 0.13), "ash_dark", yaw)
	rise = PIVOT - DECK
	cylinder("Sniper_stand", 0.22, 0.16, rise, 10, (0.0, 0.0, DECK + rise * 0.5), "iron", yaw)
	for n in range(3):
		a = n * math.tau / 3
		beam(f"Sniper_tripod{n}", (math.cos(a) * 0.75, math.sin(a) * 0.75, DECK + 0.26), (0.0, 0.0, DECK + rise * 0.55), 0.12, "ash", yaw)
	for side in (-1.0, 1.0):
		beam(f"Sniper_roofpost{int(side)}", (side * 0.85, 1.25, DECK + 0.26), (side * 0.85, 1.25, DECK + 4.4), 0.12, "ash", yaw)
		beam(f"Sniper_roofstay{int(side)}", (side * 0.85, 1.25, DECK + 1.2), (side * 0.85, 0.45, DECK + 0.26), 0.08, "ash_dark", yaw)
	canvas("Sniper_roof", ((-1.0, 1.7, DECK + 4.5), (1.0, 1.7, DECK + 4.5), (1.0, -0.1, DECK + 3.95), (-1.0, -0.1, DECK + 3.95)), yaw,
		sag=0.15, outward=(0.0, 0.0, 1.0), stripes=((0.0, 0.2),), rows=3)
	box("Sniper_seat", (0.6, 0.5, 0.12), (0.0, 1.1, DECK + 0.9), "ash_dark", yaw)
	beam("Sniper_seat_leg", (0.0, 1.1, DECK + 0.26), (0.0, 1.1, DECK + 0.85), 0.1, "ash_dark", yaw)

	pitch = Node("Sniper_Pitch", (0.0, 0.0, PIVOT), yaw)
	p = Vector((0.0, 0.0, PIVOT))
	F = FORWARD
	up = Vector((0.0, 0.0, 0.08))
	cylinder("Sniper_trunnion", 0.12, 0.12, 0.8, 8, p, "iron", pitch, axis=(1.0, 0.0, 0.0))
	box("Sniper_stock", (0.34, 2.2, 0.42), p - F * 0.9 + Vector((0.0, 0.0, -0.08)), "ash", pitch)
	box("Sniper_butt", (0.36, 0.5, 0.7), p - F * 2.0 + Vector((0.0, 0.0, -0.18)), "ash", pitch)
	with Variant(unless=("eagle",)) as on:
		if on:
			cylinder("Sniper_scope", 0.12, 0.12, 1.6, 10, p + F * 0.3 + Vector((0.0, 0.0, 0.48)), "iron", pitch, axis=F)
			cylinder("Sniper_scope_eye", 0.17, 0.12, 0.25, 10, p + F * 1.15 + Vector((0.0, 0.0, 0.48)), "iron", pitch, axis=F)
			for t in (-0.2, 0.8):
				box(f"Sniper_scope_mount{t}", (0.08, 0.12, 0.3), p + F * t + Vector((0.0, 0.0, 0.3)), "iron", pitch, bevel=0.0)
	with Variant(unless=("twin", "heavyshot")) as on:
		if on:
			cylinder("Sniper_barrel", 0.16, 0.13, 6.2, 10, p + F * 3.0 + up, "iron", pitch, axis=F)
			cylinder("Sniper_brake", 0.22, 0.22, 0.45, 10, p + F * 6.1 + up, "iron", pitch, axis=F)
			cylinder("Sniper_band", 0.2, 0.2, 0.14, 10, p + F * 1.6 + up, "sky", pitch, axis=F)
			Node("Sniper_Muzzle", p + F * 6.4 + up, pitch)
	with Variant(("quick",)) as on:
		if on:
			# A drum magazine under the barrel, ahead of the stand.
			drum = p + F * 0.6 + Vector((0.0, 0.0, -0.46))
			cylinder("Sniper_drum", 0.38, 0.38, 0.3, 14, drum, "iron", pitch, axis=(1.0, 0.0, 0.0))
			cylinder("Sniper_drum_face", 0.3, 0.3, 0.32, 14, drum, "sky", pitch, axis=(1.0, 0.0, 0.0))
	with Variant(("twin",)) as on:
		if on:
			for x in (-0.19, 0.19):
				off = Vector((x, 0.0, 0.08))
				cylinder(f"Sniper_twin_barrel{x}", 0.14, 0.12, 6.0, 10, p + F * 2.9 + off, "iron", pitch, axis=F)
				cylinder(f"Sniper_twin_brake{x}", 0.19, 0.19, 0.4, 10, p + F * 5.95 + off, "iron", pitch, axis=F)
			for t in (1.6, 4.2):
				box(f"Sniper_twin_clamp{t}", (0.68, 0.16, 0.3), p + F * t + up, "sky" if t < 2 else "iron", pitch, bevel=0.02)
			drum2 = p + F * 1.4 + Vector((0.0, 0.0, -0.46))
			cylinder("Sniper_drum2", 0.38, 0.38, 0.3, 14, drum2, "iron", pitch, axis=(1.0, 0.0, 0.0))
			cylinder("Sniper_drum2_face", 0.3, 0.3, 0.32, 14, drum2, "sky", pitch, axis=(1.0, 0.0, 0.0))
			Node("Sniper_Muzzle_twin", p + F * 6.2 + up, pitch)
	with Variant(("eagle",)) as on:
		if on:
			# A long scope with a sunshade and a brass objective.
			cylinder("Sniper_eagle_scope", 0.16, 0.16, 2.8, 10, p + F * 0.6 + Vector((0.0, 0.0, 0.55)), "iron", pitch, axis=F)
			cylinder("Sniper_eagle_shade", 0.24, 0.2, 0.6, 10, p + F * 2.2 + Vector((0.0, 0.0, 0.55)), "iron", pitch, axis=F)
			cylinder("Sniper_eagle_lens", 0.21, 0.21, 0.08, 10, p + F * 2.5 + Vector((0.0, 0.0, 0.55)), "brass", pitch, axis=F)
			cylinder("Sniper_eagle_eye", 0.24, 0.16, 0.3, 10, p + F * -0.85 + Vector((0.0, 0.0, 0.55)), "iron", pitch, axis=F)
			for t in (-0.3, 1.4):
				box(f"Sniper_eagle_mount{t}", (0.08, 0.14, 0.38), p + F * t + Vector((0.0, 0.0, 0.32)), "iron", pitch, bevel=0.0)
	with Variant(("heavyshot",)) as on:
		if on:
			# A thick barrel, a gun shield and (unless replaced) a slotted brake.
			cylinder("Sniper_heavy_barrel", 0.3, 0.24, 7.0, 12, p + F * 3.4 + up, "iron", pitch, axis=F)
			cylinder("Sniper_heavy_band", 0.35, 0.35, 0.18, 12, p + F * 1.5 + up, "sky", pitch, axis=F)
			box("Sniper_shield", (1.5, 0.08, 1.15), p + F * 0.95 + Vector((0.0, 0.0, 0.05)), "iron", pitch, bevel=0.03)
			for x in (-0.6, 0.6):
				box(f"Sniper_shield_rivets{x}", (0.08, 0.1, 1.0), p + F * 0.92 + Vector((x, 0.0, 0.05)), "ash_dark", pitch, bevel=0.0)
			with Variant(unless=("pin", "burst")) as on2:
				if on2:
					box("Sniper_heavy_brake", (0.6, 0.7, 0.5), p + F * 7.1 + up, "iron", pitch, bevel=0.05)
					for k in (-1, 1):
						box(f"Sniper_heavy_brake_slot{k}", (0.64, 0.12, 0.12), p + F * (7.1 + k * 0.18) + up, "ash_dark", pitch, bevel=0.0)
					Node("Sniper_Muzzle_heavyshot", p + F * 7.45 + up, pitch)
			with Variant(("pin",)) as on2:
				if on2:
					# A barbed harpoon head on the muzzle and a reel of line along the barrel.
					cylinder("Sniper_pin_socket", 0.3, 0.26, 0.4, 10, p + F * 7.05 + up, "iron", pitch, axis=F)
					cylinder("Sniper_pin_head", 0.28, 0.01, 1.0, 8, p + F * 7.75 + up, "iron", pitch, axis=F)
					for k in (-1, 1):
						beam(f"Sniper_pin_barb{k}", p + F * 7.4 + up, p + F * 7.0 + up + Vector((k * 0.42, 0.0, 0.0)), 0.07, "iron", pitch)
					cylinder("Sniper_pin_reel", 0.32, 0.32, 0.36, 12, p + F * 0.2 + Vector((0.55, 0.0, -0.1)), "rope", pitch, axis=(1.0, 0.0, 0.0))
					beam("Sniper_pin_line", p + F * 0.2 + Vector((0.55, 0.0, 0.2)), p + F * 7.0 + Vector((0.22, 0.0, 0.1)), 0.03, "rope", pitch)
					Node("Sniper_Muzzle_pin", p + F * 8.2 + up, pitch)
			with Variant(("burst",)) as on2:
				if on2:
					cylinder("Sniper_burst_mouth", 0.26, 0.5, 0.8, 12, p + F * 7.25 + up, "iron", pitch, axis=F)
					cylinder("Sniper_burst_band", 0.4, 0.4, 0.16, 12, p + F * 7.15 + up, "shell", pitch, axis=F)
					Node("Sniper_Muzzle_burst", p + F * 7.65 + up, pitch)
	star_ranks("Sniper", pitch, p + F * 2.0 + up, 0.38, F, pole_top, root)


# ---------------------------------------------------------------- staging

LINEUP_NAME = "TowerUpgrades"
STARS = ("star1", "star2", "star3")
# One row per tower: base, the first line with its two branches, the second line with its two
# branches, and a final state with all three stars.
LINEUP = (
	("Cannon", "build_cannon", (
		("base", ()), ("scatter", ("scatter",)), ("fan", ("scatter", "fan")), ("blaze", ("scatter", "blaze")),
		("heavy", ("heavy",)), ("lofty", ("heavy", "lofty")), ("quake", ("heavy", "quake")),
		("+3 stars", ("heavy", "quake") + STARS))),
	("Catapult", "build_catapult", (
		("base", ()), ("boulder", ("boulder",)), ("meteor", ("boulder", "meteor")), ("rubble", ("boulder", "rubble")),
		("volley", ("volley",)), ("firepot", ("volley", "firepot")), ("farthrow", ("volley", "farthrow")),
		("+3 stars", ("volley", "farthrow") + STARS))),
	("Sniper", "build_sniper", (
		("base", ()), ("quick", ("quick",)), ("twin", ("quick", "twin")), ("eagle", ("quick", "eagle")),
		("heavyshot", ("heavyshot",)), ("pin", ("heavyshot", "pin")), ("burst", ("heavyshot", "burst")),
		("+3 stars", ("heavyshot", "burst") + STARS))),
)
LINEUP_SPACING = 12.5
LINEUP_TURN = 30.0  # each tower turned so the camera, square to the row, sees its front and windmill side
LINEUP_ROW_GAP = 45.0


def clear_old_scene(name=SCENE_NAME):
	old = bpy.data.scenes.get(name)
	if old is None:
		return
	for obj in list(old.objects):
		data = obj.data
		bpy.data.objects.remove(obj, do_unlink=True)
		if data is not None and data.users == 0:
			if isinstance(data, bpy.types.Mesh):
				bpy.data.meshes.remove(data)
			elif isinstance(data, bpy.types.Light):
				bpy.data.lights.remove(data)
			elif isinstance(data, bpy.types.Camera):
				bpy.data.cameras.remove(data)
			elif isinstance(data, bpy.types.Curve):
				bpy.data.curves.remove(data)
	for coll in list(old.collection.children_recursive):
		bpy.data.collections.remove(coll)
	bpy.data.scenes.remove(old)


def stage(scene, ground_radius=40.0):
	"""Ground, sun, sky and a camera for preview renders. Lives in its own collection, not exported."""
	coll = bpy.data.collections.new("Stage")
	scene.collection.children.link(coll)
	bm = bmesh.new()
	bmesh.ops.create_circle(bm, cap_ends=True, segments=64, radius=ground_radius)
	mesh = bpy.data.meshes.new("Stage_ground")
	bm.to_mesh(mesh)
	bm.free()
	mesh.materials.append(MATS["grass"])
	_paint_variation(mesh)
	ground = bpy.data.objects.new("Stage_ground", mesh)
	coll.objects.link(ground)

	sun_data = bpy.data.lights.new("Stage_sun", "SUN")
	sun_data.energy = 4.5
	sun_data.angle = math.radians(2.5)
	sun_data.color = (1.0, 0.92, 0.8)
	sun = bpy.data.objects.new("Stage_sun", sun_data)
	sun.rotation_euler = Euler((math.radians(52.0), 0.0, math.radians(-38.0)))
	coll.objects.link(sun)

	world = bpy.data.worlds.get("WT_world") or bpy.data.worlds.new("WT_world")
	if world.node_tree is None:
		world.use_nodes = True
	nodes = world.node_tree.nodes
	bg = next((n for n in nodes if n.type == "BACKGROUND"), None)
	if bg is None:
		nodes.clear()
		bg = nodes.new("ShaderNodeBackground")
		out = nodes.new("ShaderNodeOutputWorld")
		world.node_tree.links.new(bg.outputs["Background"], out.inputs["Surface"])
	bg.inputs["Color"].default_value = (0.42, 0.55, 0.72, 1.0)
	bg.inputs["Strength"].default_value = 0.55
	scene.world = world

	cam_data = bpy.data.cameras.new("Stage_camera")
	cam_data.lens = 55.0
	cam_data.clip_end = 1000.0
	cam = bpy.data.objects.new("Stage_camera", cam_data)
	coll.objects.link(cam)
	scene.camera = cam
	return cam, coll


def aim_camera(cam, target, distance, yaw_deg, pitch_deg, lens=55.0):
	target = Vector(target)
	yaw, pitch = math.radians(yaw_deg), math.radians(pitch_deg)
	offset = Vector((math.sin(yaw) * math.cos(pitch), -math.cos(yaw) * math.cos(pitch), math.sin(pitch))) * distance
	cam.location = target + offset
	cam.rotation_mode = "QUATERNION"
	cam.rotation_quaternion = (target - cam.location).to_track_quat("-Z", "Y")
	cam.data.lens = lens


def _new_scene(name, width, height):
	scene = bpy.data.scenes.new(name)
	scene.unit_settings.system = "METRIC"
	for engine in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
		try:
			scene.render.engine = engine
			break
		except TypeError:
			continue
	scene.render.resolution_x = width
	scene.render.resolution_y = height
	scene.view_settings.view_transform = "AgX"
	for look in ("AgX - Medium High Contrast", "Medium High Contrast"):
		try:
			scene.view_settings.look = look
			break
		except TypeError:
			continue
	try:
		scene.eevee.use_shadows = True
		scene.eevee.use_raytracing = True
	except AttributeError:
		pass
	return scene


def _build_tower(name, builder, coll, offset, path, turn_deg=0.0):
	"""Builds one tower under `coll` with its root at `offset`, showing the upgrade state `path`
	(a tuple of ids, or None for every variant at once)."""
	PATH["value"] = None if path is None else set(path)
	set_style(path)
	TAGS.clear()
	root = Node(name, (0.0, 0.0, 0.0), collection=coll)
	builder(root)
	root.obj.location = Vector(offset)
	root.obj.rotation_euler = Euler((0.0, 0.0, math.radians(turn_deg)))
	# Children were placed relative to an origin of zero; shift the bookkeeping to match.
	root.origin = Vector(offset)
	return root


def build(path=()):
	"""The main scene: the three towers side by side. path=() is the unupgraded look; path=None builds
	every upgrade part at once (each tagged wt_requires / wt_unless) for export to the game."""
	clear_old_scene(SCENE_NAME)
	clear_old_scene(LINEUP_NAME)
	make_materials()
	scene = _new_scene(SCENE_NAME, 1600, 900)
	for name, x, builder in (("Cannon", -15.0, build_cannon), ("Catapult", 0.0, build_catapult), ("Sniper", 15.0, build_sniper)):
		coll = bpy.data.collections.new(name)
		scene.collection.children.link(coll)
		_build_tower(name, builder, coll, (x, 0.0, 0.0), path)
	PATH["value"] = ()
	set_style(())
	cam, _ = stage(scene)
	aim_camera(cam, (0.0, 0.0, 6.0), 62.0, -28.0, 16.0)
	for window in bpy.context.window_manager.windows:
		window.scene = scene
	return scene


LABELS = {
	"base": "基础", "scatter": "散射", "fan": "扇面", "blaze": "焚地", "heavy": "重炮", "lofty": "俯射", "quake": "震岳",
	"boulder": "巨石", "meteor": "落星", "rubble": "碎岩", "volley": "连投", "firepot": "火罐", "farthrow": "远投",
	"quick": "速射", "twin": "连珠", "eagle": "鹰眼", "heavyshot": "重狙", "pin": "钉足", "burst": "爆裂", "+3 stars": "+3 星",
}


def _label(text, at, coll, yaw_deg, size=1.9):
	curve = bpy.data.curves.new("Label_" + text, "FONT")
	curve.body = LABELS.get(text, text)
	for path in ("C:/Windows/Fonts/msyhbd.ttc", "C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"):
		try:
			curve.font = bpy.data.fonts.load(path, check_existing=True)
			break
		except (RuntimeError, OSError):
			continue
	curve.size = size
	curve.align_x = "CENTER"
	curve.extrude = 0.04
	curve.materials.append(MATS["ash_dark"])
	obj = bpy.data.objects.new("Label_" + text, curve)
	obj.location = Vector(at)
	obj.rotation_euler = Euler((math.pi * 0.5, 0.0, math.radians(yaw_deg)))
	coll.objects.link(obj)
	return obj


def build_lineup():
	"""A second scene, "TowerUpgrades": one row per tower, each column one upgrade state."""
	clear_old_scene(LINEUP_NAME)
	make_materials()
	scene = _new_scene(LINEUP_NAME, 2400, 860)
	cam, stage_coll = stage(scene, ground_radius=160.0)
	cam.data.type = "ORTHO"
	builders = {"build_cannon": build_cannon, "build_catapult": build_catapult, "build_sniper": build_sniper}
	for row, (tower, builder_name, states) in enumerate(LINEUP):
		row_coll = bpy.data.collections.new("Up_" + tower)
		scene.collection.children.link(row_coll)
		y = row * LINEUP_ROW_GAP
		for k, (label, path) in enumerate(states):
			x = (k - (len(states) - 1) * 0.5) * LINEUP_SPACING
			coll = bpy.data.collections.new(f"Up_{tower}_{k}_{label}")
			row_coll.children.link(coll)
			_build_tower(f"Up_{tower}_{k}", builders[builder_name], coll, (x, y, 0.0), path, LINEUP_TURN)
			_label(label, (x, y - 8.0, 0.4), coll, 0.0)
	PATH["value"] = ()
	set_style(())
	return scene


def render_lineup(folder, yaw_deg=0.0, pitch_deg=26.0, scale=100.0):
	scene = bpy.data.scenes[LINEUP_NAME]
	cam = scene.camera
	cam.data.ortho_scale = scale
	rows = [c for c in scene.collection.children if c.name.startswith("Up_")]
	written = []
	for row, (tower, _, _) in enumerate(LINEUP):
		for c in rows:
			c.hide_render = c.name != "Up_" + tower
		aim_camera(cam, (0.0, row * LINEUP_ROW_GAP, (6.0, 3.5, 8.0)[row]), 250.0, yaw_deg, pitch_deg)
		scene.render.filepath = f"{folder}/upgrades_{tower.lower()}.png"
		bpy.ops.render.render(write_still=True, scene=scene.name)
		written.append(scene.render.filepath)
	for c in rows:
		c.hide_render = False
	return written


def render(path, target=(0.0, 0.0, 6.0), distance=62.0, yaw=-28.0, pitch=16.0, lens=55.0):
	scene = bpy.data.scenes[SCENE_NAME]
	aim_camera(scene.camera, target, distance, yaw, pitch, lens)
	scene.render.filepath = path
	bpy.ops.render.render(write_still=True, scene=scene.name)


def _tris(coll):
	return sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in coll.all_objects if o.type == "MESH")


def tri_count(scene_name=SCENE_NAME):
	scene = bpy.data.scenes[scene_name]
	totals = {}
	for coll in scene.collection.children:
		if coll.name.startswith("Stage"):
			continue
		if coll.children:
			for sub in coll.children:
				totals[sub.name] = _tris(sub)
		else:
			totals[coll.name] = _tris(coll)
	return totals


# ---------------------------------------------------------------- export

EXPORTS = (("Cannon", "cannon", "build_cannon"), ("Catapult", "catapult", "build_catapult"), ("Sniper", "sniper", "build_sniper"))


def _merge_parts(coll):
	"""Merges the meshes that share a parent node and the same upgrade tags into one object, so the
	game draws a few dozen meshes per tower instead of hundreds. Done with bmesh, not the join
	operator, which can crash Blender when run from a script."""
	groups = {}
	for obj in coll.all_objects:
		if obj.type == "MESH":
			key = (obj.parent, obj.get("wt_requires", ""), obj.get("wt_unless", ""))
			groups.setdefault(key, []).append(obj)
	for (parent, requires, unless), objs in groups.items():
		name = parent.name
		if requires:
			name += "__" + requires.replace(",", "_")
		if unless:
			name += "__not_" + unless.replace(",", "_")
		name += "__mesh"
		bm = bmesh.new()
		materials = []
		for obj in objs:
			mesh = obj.data.copy()
			mesh.transform(obj.matrix_basis)
			first = len(bm.faces)
			bm.from_mesh(mesh)
			bm.faces.ensure_lookup_table()
			remap = []
			for mat in mesh.materials:
				if mat not in materials:
					materials.append(mat)
				remap.append(materials.index(mat))
			for face in bm.faces[first:]:
				face.material_index = remap[face.material_index] if remap else 0
			bpy.data.meshes.remove(mesh)
		merged = bpy.data.meshes.new(name)
		bm.to_mesh(merged)
		bm.free()
		for mat in materials:
			merged.materials.append(mat)
		if "Col" in merged.color_attributes:
			merged.color_attributes.active_color = merged.color_attributes["Col"]
		obj = bpy.data.objects.new(name, merged)
		for key in ("wt_requires", "wt_unless"):
			if key in objs[0]:
				obj[key] = objs[0][key]
		coll.objects.link(obj)
		obj.parent = parent
		for old in objs:
			data = old.data
			bpy.data.objects.remove(old, do_unlink=True)
			if data.users == 0:
				bpy.data.meshes.remove(data)


def export_glb(folder):
	"""Writes one .glb per tower with every upgrade part in it. Run it in a background Blender
	(see export_towers.py): it empties the active scene, because the glTF exporter crashes when
	pointed at any other scene."""
	if not bpy.app.background:
		raise RuntimeError("Run export_towers.py with blender --background; it empties the active scene.")
	clear_old_scene(SCENE_NAME)
	clear_old_scene(LINEUP_NAME)
	make_materials()
	scene = bpy.context.scene
	builders = {"build_cannon": build_cannon, "build_catapult": build_catapult, "build_sniper": build_sniper}
	written = {}
	for name, file_name, builder_name in EXPORTS:
		for obj in list(scene.objects):
			bpy.data.objects.remove(obj, do_unlink=True)
		for child in list(scene.collection.children):
			bpy.data.collections.remove(child)
		coll = bpy.data.collections.new("Export_" + name)
		_build_tower(name, builders[builder_name], coll, (0.0, 0.0, 0.0), None)
		_merge_parts(coll)
		scene.collection.children.link(coll)
		for obj in scene.objects:
			obj.select_set(True)
		options = dict(filepath=f"{folder}/{file_name}.glb", export_format="GLB", use_selection=True, export_extras=True,
			export_yup=True, export_cameras=False, export_lights=False, export_animations=False)
		try:
			bpy.ops.export_scene.gltf(**options, export_vertex_color="ACTIVE")
		except TypeError:
			bpy.ops.export_scene.gltf(**options)
		written[file_name] = {"meshes": len([o for o in coll.all_objects if o.type == "MESH"]), "triangles": _tris(coll)}
	for obj in list(scene.objects):
		bpy.data.objects.remove(obj, do_unlink=True)
	for child in list(scene.collection.children):
		bpy.data.collections.remove(child)
	PATH["value"] = ()
	set_style(())
	return written


if __name__ == "__main__":
	build()
