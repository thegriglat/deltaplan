class_name EggMeteor
extends EasterEgg
## Метеор: короткий светящийся штрих по тёмному ясному небу. Чисто визуально. Направление
## (азимут, высота, направление полёта) — из rng в begin, в мировых осях: у двоих в сети одно и
## то же место неба. Рисуется на фиксированной дальности от камеры вдоль мирового направления.

const SHADER := preload("res://scripts/world_objects/easter_eggs/meteor.gdshader")

var _mat: ShaderMaterial
var _dur := 1.0
var _speed := 0.5  # рад/с
var _trail := 0.2  # рад
var _travel := 0.3  # рад
var _dir_mid := Vector3.FORWARD  # мировое направление на середину пути
var _bright := 1.0
var _range := 30000.0
var _basis := Basis.IDENTITY
var _mi: MeshInstance3D
var _span := 1.0


static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	if ctx.to_sun.y > sin(deg_to_rad(float(cfg.get("sun_alt_max_deg", -12.0)))):
		return false
	if ctx.weather.is_empty():
		return true
	var d: Dictionary = ctx.weather.get("_derived", {})
	if String(d.get("sky", "clear")) == "overcast":
		return false
	return float(ctx.weather.get("cirrus_cover", 0.0)) < float(cfg.get("cirrus_max", 0.3))


func begin(_ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, _t0: float) -> void:
	var bolide := rng.randf() < float(cfg.get("bolide_chance", 0.08))
	var az := rng.randf() * TAU
	var alt := deg_to_rad(rng.randf_range(float(cfg.alt_deg[0]), float(cfg.alt_deg[1])))
	var course := rng.randf() * TAU  # направление полёта на сфере неба
	var dur_r: Array = cfg.bolide_duration_s if bolide else cfg.duration_s
	var trail_r: Array = cfg.bolide_trail_deg if bolide else cfg.trail_deg
	_dur = rng.randf_range(float(dur_r[0]), float(dur_r[1]))
	_trail = deg_to_rad(rng.randf_range(float(trail_r[0]), float(trail_r[1])))
	_speed = deg_to_rad(rng.randf_range(float(cfg.speed_deg_s[0]), float(cfg.speed_deg_s[1])))
	_travel = _speed * _dur
	_bright = float(cfg.bolide_brightness if bolide else cfg.brightness) * rng.randf_range(0.7, 1.0)
	_range = float(cfg.distance_m)
	# середина пути; мир: Y вверх, азимут от -Z по часовой
	_dir_mid = Vector3(sin(az) * cos(alt), sin(alt), -cos(az) * cos(alt))
	var east := Vector3.UP.cross(_dir_mid).normalized()
	var north := _dir_mid.cross(east).normalized()
	var tangent := east * cos(course) + north * sin(course)
	# плоскость: +Z смотрит на камеру, X — вдоль пути
	var z := -_dir_mid
	var y := z.cross(tangent).normalized()
	_basis = Basis(tangent, y, z)
	var span := _travel + _trail
	span = minf(span, deg_to_rad(80.0))
	var quad := QuadMesh.new()
	var th := tan(span * 0.5)
	var half_h := 0.03
	quad.size = Vector2(2.0 * _range * th, 2.0 * _range * half_h)
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("tan_half", th)
	_mat.set_shader_parameter("half_height", half_h)
	_mat.set_shader_parameter("trail_rad", _trail)
	_mat.set_shader_parameter("width_rad", float(cfg.width_deg) * PI / 180.0)
	quad.material = _mat
	_mi = MeshInstance3D.new()
	_mi.mesh = quad
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mi.extra_cull_margin = 16384.0
	add_child(_mi)
	_span = span


func sky_dir() -> Vector3:
	return _dir_mid


func update(ctx: EggContext) -> bool:
	var age := ctx.t - t0
	var end_s := _dur + 0.35
	if age > end_s or age < 0.0:
		return false
	var head := -_span * 0.5 + _speed * minf(age, _dur)
	var fade := 1.0
	if age < 0.06:
		fade = age / 0.06
	elif age > _dur:
		fade = clampf(1.0 - (age - _dur) / 0.35, 0.0, 1.0)
	else:
		fade = 1.0 - 0.6 * age / _dur  # к концу тускнеет
	_mat.set_shader_parameter("head_rad", head)
	_mat.set_shader_parameter("intensity", _bright * fade)
	var origin := ctx.camera.global_position if ctx.camera != null else ctx.pilot_pos
	global_transform = Transform3D(_basis, origin + _dir_mid * _range)
	return true
