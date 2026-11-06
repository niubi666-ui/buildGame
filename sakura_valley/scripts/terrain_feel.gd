extends Node
## What makes reshaping the ground feel physical: dust, flying soil, a low rumble and a slight tremor.
## Others call shake() while earth is moving. This node never changes the game itself.

const SAMPLE_RATE := 22050.0
const DUST_RISE := Color(0.72, 0.62, 0.48, 0.5)

var main: Node3D
var dust: GPUParticles3D
var dust_material: ParticleProcessMaterial
var soil: GPUParticles3D
var soil_material: ParticleProcessMaterial
var player: AudioStreamPlayer
var playback: AudioStreamGeneratorPlayback
var rumble := 0.0
var rumble_target := 0.0
var last_shake := -10.0
var brown := 0.0
var noise_state := 7213
var rumble_db := -9.0
var tremor := 0.35


func setup(main_node: Node3D, feel_config: Dictionary) -> void:
	main = main_node
	rumble_db = feel_config["rumble_volume_db"]
	tremor = feel_config["camera_shake"]
	_build_dust()
	_build_soil()
	_build_audio()


func _build_dust() -> void:
	dust_material = ParticleProcessMaterial.new()
	dust_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	dust_material.emission_sphere_radius = 8.0
	dust_material.direction = Vector3.UP
	dust_material.spread = 35.0
	dust_material.initial_velocity_min = 1.0
	dust_material.initial_velocity_max = 3.5
	dust_material.gravity = Vector3(0.3, 0.25, 0.15)
	dust_material.scale_min = 1.6
	dust_material.scale_max = 4.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
	ramp.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	ramp.add_point(0.18, Color(1.0, 1.0, 1.0, 1.0))
	var ramp_texture := GradientTexture1D.new()
	ramp_texture.gradient = ramp
	dust_material.color_ramp = ramp_texture
	var puff := Gradient.new()
	puff.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	puff.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var puff_texture := GradientTexture2D.new()
	puff_texture.gradient = puff
	puff_texture.fill = GradientTexture2D.FILL_RADIAL
	puff_texture.fill_from = Vector2(0.5, 0.5)
	puff_texture.fill_to = Vector2(1.0, 0.5)
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = puff_texture
	material.albedo_color = DUST_RISE
	var quad := QuadMesh.new()
	quad.material = material
	dust = GPUParticles3D.new()
	dust.amount = 70
	dust.lifetime = 1.4
	dust.emitting = false
	dust.process_material = dust_material
	dust.draw_pass_1 = quad
	dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dust.visibility_aabb = AABB(Vector3(-80.0, -30.0, -80.0), Vector3(160.0, 80.0, 160.0))
	add_child(dust)


func _build_soil() -> void:
	soil_material = ParticleProcessMaterial.new()
	soil_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	soil_material.emission_sphere_radius = 8.0
	soil_material.direction = Vector3.UP
	soil_material.spread = 55.0
	soil_material.initial_velocity_min = 4.0
	soil_material.initial_velocity_max = 10.0
	soil_material.gravity = Vector3(0.0, -18.0, 0.0)
	soil_material.angular_velocity_min = -300.0
	soil_material.angular_velocity_max = 300.0
	soil_material.scale_min = 0.5
	soil_material.scale_max = 1.3
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.36, 0.27, 0.2)
	material.roughness = 1.0
	var clod := BoxMesh.new()
	clod.size = Vector3(0.3, 0.22, 0.3)
	clod.material = material
	soil = GPUParticles3D.new()
	soil.amount = 80
	soil.lifetime = 1.1
	soil.emitting = false
	soil.process_material = soil_material
	soil.draw_pass_1 = clod
	soil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	soil.visibility_aabb = AABB(Vector3(-80.0, -30.0, -80.0), Vector3(160.0, 80.0, 160.0))
	add_child(soil)


## A low rumble made from filtered noise, so the project needs no sound files.
func _build_audio() -> void:
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = SAMPLE_RATE
	stream.buffer_length = 0.2
	player = AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = rumble_db
	add_child(player)
	player.play()
	playback = player.get_stream_playback()


## Call each frame while earth is moving. Strength runs from 0 to 1.
func shake(at: Vector3, radius: float, strength: float) -> void:
	last_shake = Time.get_ticks_msec() / 1000.0
	rumble_target = maxf(rumble_target, clampf(strength, 0.0, 1.0))
	dust.global_position = at
	soil.global_position = at
	dust_material.emission_sphere_radius = radius * 0.7
	soil_material.emission_sphere_radius = radius * 0.6
	dust.emitting = true
	soil.emitting = true


func _process(delta: float) -> void:
	var quiet := Time.get_ticks_msec() / 1000.0 - last_shake > 0.1
	if quiet:
		rumble_target = 0.0
		dust.emitting = false
		soil.emitting = false
	rumble = move_toward(rumble, rumble_target, delta * 3.5)
	rumble_target = 0.0 if quiet else rumble_target
	_fill_audio()
	main.camera_tremor = rumble * tremor


func _fill_audio() -> void:
	if playback == null:
		return
	var frames := playback.get_frames_available()
	for n in frames:
		# A small generator keeps this cheap. Summing it into itself leaves only the low tones.
		noise_state = (noise_state * 1103515245 + 12345) & 0x7fffffff
		var white := float(noise_state) / 1073741823.5 - 1.0
		brown = clampf(brown * 0.995 + white * 0.03, -1.0, 1.0)
		var value := brown * rumble * 1.6
		playback.push_frame(Vector2(value, value))
