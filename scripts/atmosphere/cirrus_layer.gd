class_name CirrusLayer
extends Node3D
## Перистая пелена (VR-28): плоскость на высоте cirrus.altitude_msl_m, за камерой.
## Покрытие — weather.cirrus_cover; оно же ослабляет прогрев земли (Atmosphere.get_insolation).

var atmo: Atmosphere
var cfg: Dictionary
var _mi: MeshInstance3D
var _mat: ShaderMaterial
var _sun: DirectionalLight3D


func setup(atmosphere: Atmosphere) -> void:
	atmo = atmosphere
	cfg = atmo.cfg.cirrus
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://scripts/atmosphere/cirrus.gdshader")
	var n := FastNoiseLite.new()
	n.seed = int(atmo.cfg.seed) + 91
	n.noise_type = FastNoiseLite.TYPE_PERLIN
	n.fractal_octaves = 5
	n.frequency = 4.0 / 512.0
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 512
	tex.seamless = true
	tex.generate_mipmaps = true
	tex.noise = n
	_mat.set_shader_parameter("noise", tex)
	var params := {
		"flow_period_m": "flow_period_m", "flow_bend_m": "flow_bend_m",
		"band_period_m": "band_period_m", "band_stretch": "band_stretch",
		"fiber_period_m": "fiber_period_m", "fiber_stretch": "fiber_stretch",
		"veil_period_m": "veil_period_m", "opacity": "opacity", "halo_strength": "halo_strength",
		"tau_max": "tau_max",
	}
	for u in params:
		_mat.set_shader_parameter(u, float(cfg[params[u]]))
	var c: Array = cfg.color
	_mat.set_shader_parameter("color", Vector3(float(c[0]), float(c[1]), float(c[2])))
	_mat.set_shader_parameter("halo_rad", deg_to_rad(float(cfg.halo_deg)))
	_mat.set_shader_parameter("half_size_m", float(cfg.size_m) * 0.5)
	var pm := PlaneMesh.new()
	pm.size = Vector2(float(cfg.size_m), float(cfg.size_m))
	pm.subdivide_width = 16
	pm.subdivide_depth = 16
	_mi = MeshInstance3D.new()
	_mi.mesh = pm
	_mi.material_override = _mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Рисуется раньше кучевых (они ниже и ближе).
	_mi.sorting_offset = -1.0e6
	_mi.extra_cull_margin = 1.0e5
	add_child(_mi)


func _process(_delta: float) -> void:
	if atmo == null:
		return
	var cover := clampf(float(atmo.weather.get("cirrus_cover", 0.0)), 0.0, 1.0)
	_mi.visible = cover > 0.01
	if not _mi.visible:
		return
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam != null else atmo.get_focus()
	_mi.global_position = Vector3(eye.x, float(cfg.altitude_msl_m), eye.z)
	var w := atmo.wind.vec2_at(1000.0) * float(cfg.drift_factor)
	_mat.set_shader_parameter("cover", cover)
	_mat.set_shader_parameter("wind_dir", w.normalized() if w.length() > 0.01 else Vector2(1, 0))
	_mat.set_shader_parameter("drift", -w * atmo.time_s)
	if _sun == null or not is_instance_valid(_sun):
		_sun = _find_light(get_tree().root)
	if _sun != null:
		_mat.set_shader_parameter("sun_dir", _sun.global_transform.basis.z.normalized())
		_mat.set_shader_parameter("sun_energy", _sun.light_energy)


func _find_light(n: Node) -> DirectionalLight3D:
	if n is DirectionalLight3D:
		return n
	for c in n.get_children():
		var r := _find_light(c)
		if r != null:
			return r
	return null
