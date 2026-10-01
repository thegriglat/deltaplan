class_name EggAirliner
extends EasterEgg
## Лайнер на эшелоне с инверсионным следом (чисто картинка). Прямая в мировых координатах на
## высоте 9–11 км; положение и след — функции ctx.t − t0. Живучесть следа — из cirrus_cover.

const SEGMENTS := 48

var _p0 := Vector3.ZERO  # положение самолёта в t0
var _dir := Vector3.FORWARD  # единичный курс (горизонтальный)
var _speed := 230.0
var _trail_life := 60.0
var _cap_m := 48000.0
var _trail: MeshInstance3D
var _mat: ShaderMaterial


## Небо не сплошь закрыто и солнце не сильно ниже горизонта (ночью следа не видно).
static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	if _sky(ctx.weather) == "overcast":
		return false
	return ctx.to_sun.y > float(cfg.get("min_sun_y", -0.1))


static func _sky(w: Dictionary) -> String:
	var d: Dictionary = w.get("_derived", {})
	return String(d.get("sky", w.get("sky", "clear")))


## Живучесть следа, с: сухой верх (cirrus_cover ≤ dry_cover) — trail_dry_s, влажный
## (cirrus_cover ≥ wet_cover) — trail_wet_s, между — линейно.
static func trail_life(cirrus_cover: float, cfg: Dictionary) -> float:
	var a := float(cfg.get("dry_cover", 0.1))
	var b := float(cfg.get("wet_cover", 0.6))
	var f := clampf((cirrus_cover - a) / maxf(b - a, 0.01), 0.0, 1.0)
	return lerpf(float(cfg.get("trail_dry_s", 32.0)), float(cfg.get("trail_wet_s", 480.0)), f)


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, _t0: float) -> void:
	# порядок бросков: курс, смещение прямой, высота
	var hdg := rng.randf() * TAU
	var off := (rng.randf() * 2.0 - 1.0) * float(cfg.get("max_offset_m", 15000.0))
	var alt_r: Array = cfg.get("altitude_m", [9000.0, 11000.0])
	var alt := lerpf(float(alt_r[0]), float(alt_r[1]), rng.randf())
	_speed = float(cfg.get("speed_ms", 230.0))
	_dir = Vector3(cos(hdg), 0.0, sin(hdg))
	var perp := Vector3(-_dir.z, 0.0, _dir.x)
	# ближайшая к центру точка — в середине жизни
	_p0 = perp * off - _dir * _speed * lifetime_s * 0.5
	_p0.y = alt
	_trail_life = trail_life(float(ctx.weather.get("cirrus_cover", 0.0)), cfg)
	_cap_m = float(cfg.get("trail_max_m", 60000.0))
	var wet := clampf(_trail_life / maxf(float(cfg.get("trail_wet_s", 480.0)), 1.0), 0.0, 1.0)
	_build_plane(cfg)
	_build_trail(cfg, wet)
	update(ctx)


func _build_plane(cfg: Dictionary) -> void:
	var len_m := float(cfg.get("plane_length_m", 40.0))
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	var body := CylinderMesh.new()
	body.top_radius = len_m * 0.045
	body.bottom_radius = len_m * 0.045
	body.height = len_m
	body.radial_segments = 8
	body.rings = 1
	body.material = mat
	var wing := BoxMesh.new()
	wing.size = Vector3(len_m * 0.9, len_m * 0.012, len_m * 0.16)
	wing.material = mat
	var mb := MeshInstance3D.new()
	mb.mesh = body
	mb.rotation.x = PI * 0.5  # ось цилиндра — вдоль Z
	mb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mb)
	var mw := MeshInstance3D.new()
	mw.mesh = wing
	mw.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mw)


func _build_trail(cfg: Dictionary, wet: float) -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in SEGMENTS + 1:
		var u := float(i) / SEGMENTS
		verts.append(Vector3.ZERO)
		uvs.append(Vector2(-1.0, u))
		verts.append(Vector3.ZERO)
		uvs.append(Vector2(1.0, u))
	for i in SEGMENTS:
		var a := i * 2
		idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.custom_aabb = AABB(Vector3(-100000, -100000, -100000), Vector3(200000, 200000, 200000))
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://assets/easter_eggs/airliner/contrail.gdshader")
	_mat.set_shader_parameter(&"start_m", float(cfg.get("trail_start_m", 80.0)))
	_mat.set_shader_parameter(&"speed_ms", _speed)
	_mat.set_shader_parameter(&"trail_life_s", _trail_life)
	_mat.set_shader_parameter(&"width0_m", float(cfg.get("width0_m", 12.0)))
	var sp := lerpf(float(cfg.get("spread_dry_ms", 1.5)), float(cfg.get("spread_wet_ms", 8.0)), wet)
	_mat.set_shader_parameter(&"spread_ms", sp)
	_mat.set_shader_parameter(&"alpha0", lerpf(0.8, 0.95, wet))
	_trail = MeshInstance3D.new()
	_trail.mesh = mesh
	_trail.material_override = _mat
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail.extra_cull_margin = 16384.0
	add_child(_trail)


func update(ctx: EggContext) -> bool:
	var age := ctx.t - t0
	if lifetime_s > 0.0 and age > lifetime_s:
		return false
	position = _p0 + _dir * _speed * age
	# самолёт смотрит по курсу (-Z узла вперёд), лента уходит назад (+Z)
	basis = Basis.looking_at(_dir, Vector3.UP)
	if _mat != null:
		var len_m := minf(_speed * minf(age, _trail_life), _cap_m)
		_mat.set_shader_parameter(&"length_m", maxf(len_m, 100.0))
		_trail.visible = age > 1.0
	return true
