extends Node
## Places one ridge at many spots and angles on the west road and checks whether it really turns the
## west group onto the east road. Shows how exact the player has to be. Run with: -- --ridgesweep

const XS := [-140.0, -134.0, -128.0, -122.0, -118.0, -112.0, -106.0, -102.0, -96.0, -90.0, -84.0]
const ZS := [-55.0, -35.0, -15.0, 5.0, 25.0]
const YAWS_DEGREES := [0.0, 15.0, 30.0, -15.0, -30.0]
## Whether the ridge may pick its own angle, as it does for the player until they turn it by hand.
const TURN := true

var main: Node3D


func run(main_node: Node3D) -> void:
	main = main_node
	var paths: Node = main.paths
	var tools: Node = main.tools
	var terrain = main.terrain
	paths.set_process(false)
	main.towers.set_process(false)
	await get_tree().process_frame
	var ridge: Dictionary = {}
	for entry: Dictionary in tools.presets:
		if entry["id"] == "ridge":
			ridge = entry
	var heights: PackedFloat32Array = terrain.heights.duplicate()
	var worked := 0
	var tried := 0
	var solve_ms := 0.0
	var fit_ms := 0.0
	for yaw_degrees: float in YAWS_DEGREES:
		var yaw := deg_to_rad(yaw_degrees)
		for z: float in ZS:
			var row := "yaw %+3d z %+4d: " % [int(yaw_degrees), int(z)]
			for x: float in XS:
				terrain.heights = heights.duplicate()
				var begin := Time.get_ticks_usec()
				var placed: Dictionary = tools.fit_preset(ridge, Vector2(x, z), yaw, TURN)
				fit_ms += float(Time.get_ticks_usec() - begin) / 1000.0
				var turned: float = placed["yaw"]
				var shape: Dictionary = placed["preset"]
				var at: Vector2 = placed["at"]
				var preview: Dictionary = terrain.preview_preset(shape, at.x, at.y, turned)
				var patch: Dictionary = terrain.make_preset_patch(shape, at.x, at.y, turned)
				terrain.set_patch_progress(patch, 1.0)
				paths.replan()
				solve_ms += paths.last_solve_ms
				var label: String = paths.gate_plans[0]["label"]
				var ok := label == "走东路"
				worked += 1 if ok else 0
				tried += 1
				var open: Array = placed.get("open", [])
				row += ("Y" if ok else ".") + str(open.size()) + ("%3d " % int(float(shape["length"])))
			print("SWEEP ", row)
	print("SWEEP x columns: ", XS)
	print("SWEEP %d of %d placements turn the west group east; solve %.1f ms, fit %.2f ms on average; turning %s" % [worked, tried, solve_ms / float(tried), fit_ms / float(tried), TURN])
	terrain.heights = heights
	get_tree().quit()
