extends RefCounted
## The towers' 3D models. Each tower type is one .glb in assets/models/towers, made in Blender by
## art/models/towers/build_windmill_towers.py, and it holds every upgrade part at once. Upgrades
## show and hide parts and repaint the cloth; nothing is rebuilt.
##
## Parts carry glTF extras from Blender: wt_requires = "a,b" shows a part only when the tower's
## path has all of those ids, wt_unless = "c,d" hides it when the path has any of them. Stars count
## as the ids star1, star2 and star3. Colours, files and each upgrade's look are in data/tower_models.json.

const GameConfig = preload("res://scripts/game_config.gd")
const Props = preload("res://scripts/props.gd")
const CLOTH_SHADER := preload("res://shaders/tower_cloth.gdshader")
const PATTERNS := {"bands": 0, "vertical": 1, "dipped": 2}

static var _scenes := {}
static var _solids := {}
static var _cloth := {}


static func config() -> Dictionary:
	return GameConfig.load_json("tower_models.json")


## Puts a tower type's model under parent, unupgraded. Returns its turret: the "yaw" node turns
## about the tower's axis, the "pitch" node tilts the gun (its +Z is the barrel).
static func build(parent: Node3D, model: String) -> Dictionary:
	var models: Dictionary = config()["models"]
	if not models.has(model):
		push_error("No tower model called %s in data/tower_models.json" % model)
		model = "cannon"
	var info: Dictionary = models[model]
	if not _scenes.has(model):
		_scenes[model] = load(String(info["file"]))
	var root: Node3D = (_scenes[model] as PackedScene).instantiate()
	parent.add_child(root)
	var prefix := String(info["prefix"])
	var pitch: Node3D = root.find_child(prefix + "_Pitch", true, false)
	pitch.rotation.x = float(info.get("rest_pitch", 0.0))
	var turret := {
		"yaw": root.find_child(prefix + "_Yaw", true, false), "pitch": pitch, "model": model, "root": root,
		"parts": [], "vanes": [], "cloth": [],
	}
	_collect(root, turret)
	dress(turret, [], 0)
	return turret


## Shows the parts for an upgrade path and star count, and paints the cloth in that upgrade's colours.
static func dress(turret: Dictionary, path: Array, stars: int) -> void:
	var taken := {}
	for id in path:
		taken[String(id)] = true
	for n in stars:
		taken["star%d" % (n + 1)] = true
	for part: Dictionary in turret["parts"]:
		var show := true
		for id: String in part["requires"]:
			show = show and taken.has(id)
		for id: String in part["unless"]:
			show = show and not taken.has(id)
		(part["node"] as Node3D).visible = show
	var look := _look(path)
	for slot: Array in turret["cloth"]:
		(slot[0] as MeshInstance3D).set_surface_override_material(slot[1], _cloth_material(look["accent"], look["pattern"], slot[2]))


## Turns the visible windmill rotors. Each spins about its hub's outward axis, the node's local X.
static func spin(turret: Dictionary, delta: float) -> void:
	var step := TAU * float(config().get("vane_turns_per_second", 0.1)) * delta
	for vane: Node3D in turret["vanes"]:
		if vane.is_visible_in_tree():
			vane.rotate_object_local(Vector3.RIGHT, step)


## The accent colour and stripe pattern for a path: the first-tier upgrade sets the pattern for its
## line, and the deepest upgrade with a colour sets the accent.
static func _look(path: Array) -> Dictionary:
	var settings := config()
	var looks: Dictionary = settings["upgrades"]
	var accent := "base"
	var pattern := "bands"
	for id in path:
		var look: Dictionary = looks.get(String(id), {})
		accent = String(look.get("accent", accent))
		pattern = String(look.get("pattern", pattern))
	return {"accent": Color(String(settings["accents"].get(accent, settings["accents"]["base"]))), "pattern": PATTERNS.get(pattern, 0)}


## Walks the imported model once: swaps every surface onto the game's own materials, notes the parts
## upgrades toggle, the windmill rotors and the cloth surfaces that upgrades repaint.
static func _collect(node: Node, turret: Dictionary) -> void:
	if node.has_meta("extras"):
		var extras: Dictionary = node.get_meta("extras")
		var requires := _ids(extras.get("wt_requires", ""))
		var unless := _ids(extras.get("wt_unless", ""))
		if not requires.is_empty() or not unless.is_empty():
			turret["parts"].append({"node": node, "requires": requires, "unless": unless})
	if node.name.contains("_Vanes") and not node is MeshInstance3D:
		turret["vanes"].append(node)
	if node is MeshInstance3D:
		var mesh: Mesh = node.mesh
		var colours: Dictionary = config()["materials"]
		for i in mesh.get_surface_count():
			var source := mesh.surface_get_material(i)
			var key := source.resource_name.trim_prefix("WT_") if source != null else ""
			if key == "canvas" or key == "sky":
				turret["cloth"].append([node, i, key == "sky"])
			elif colours.has(key):
				node.set_surface_override_material(i, _solid(colours[key]))
			else:
				push_warning("Tower model %s uses a material missing from data/tower_models.json: %s" % [turret["model"], key])
	for child in node.get_children():
		_collect(child, turret)


static func _ids(text: String) -> PackedStringArray:
	return text.split(",", false)


## One material per colour entry, shared by every tower: the scenery's solid shader with the
## entry's roughness and glow.
static func _solid(entry: Dictionary) -> ShaderMaterial:
	var key := str(entry)
	if not _solids.has(key):
		var colour := Color(String(entry["color"]))
		var material: ShaderMaterial = Props.solid(colour, 0.1, 3.0).duplicate()
		material.set_shader_parameter("roughness", float(entry.get("roughness", 0.88)))
		var glow := float(entry.get("glow", 0.0))
		if glow > 0.0:
			material.set_shader_parameter("emission", colour)
			material.set_shader_parameter("emission_energy", glow)
		_solids[key] = material
	return _solids[key]


static func _cloth_material(accent: Color, pattern: int, baked_accent: bool) -> ShaderMaterial:
	var key := "%s_%d_%s" % [accent.to_html(), pattern, baked_accent]
	if not _cloth.has(key):
		var material := ShaderMaterial.new()
		material.shader = CLOTH_SHADER
		material.set_shader_parameter("cloth", Color(String(config()["cloth"])))
		material.set_shader_parameter("accent", accent)
		material.set_shader_parameter("pattern", pattern)
		material.set_shader_parameter("baked_accent", baked_accent)
		_cloth[key] = material
	return _cloth[key]
