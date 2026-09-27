class_name BirdFlock
extends Node3D
## Птицы, кружащие в сильных термиках рядом с камерой — естественный признак термика (FR-22).
## Одна MultiMesh на всех птиц. Модель — configs/atmosphere.json → birds.model_path,
## если файла нет — простая процедурная «галочка».

var atmo: Atmosphere
var cfg: Dictionary

var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
## Стаи: [термик, [птица: Vector4(фаза угла, радиус, доля высоты, направление ±1)]].
var _flocks: Array = []
var _acc: float = 1.0e9


func setup(atmosphere: Atmosphere) -> void:
	atmo = atmosphere
	cfg = atmo.cfg.birds
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = _load_mesh(String(cfg.model_path))
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/atmosphere/bird.gdshader")
	var c: Array = cfg.color
	mat.set_shader_parameter("color", Color(float(c[0]), float(c[1]), float(c[2])))
	mat.set_shader_parameter("flap_hz", float(cfg.flap_hz))
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.material_override = mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mmi)


## Меш птицы из модели (первый MeshInstance3D, масштаб — по размаху из конфига) или заглушка.
func _load_mesh(path: String) -> Mesh:
	if path != "" and ResourceLoader.exists(path):
		var scene: PackedScene = load(path)
		if scene != null:
			var root := scene.instantiate()
			var mi := _find_mesh(root)
			var mesh: Mesh = mi.mesh if mi != null else null
			root.free()
			if mesh != null:
				return mesh
	push_warning("BirdFlock: модель '%s' не найдена — процедурная заглушка" % path)
	var half := float(cfg.span_m) * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in [1.0, -1.0]:
		st.add_vertex(Vector3(0, 0, -0.15))
		st.add_vertex(Vector3(s * half, 0.08, 0.05))
		st.add_vertex(Vector3(0, 0, 0.2))
	return st.commit()


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null


func _process(delta: float) -> void:
	if atmo == null:
		return
	_acc += delta
	if _acc > 1.0:
		_acc = 0.0
		_choose_flocks()
	_place_birds()


## Выбрать ближайшие сильные зрелые термики и раздать им птиц (детерминированно от id термика).
func _choose_flocks() -> void:
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam != null else atmo.get_focus()
	var cands: Array = []
	var r2 := float(cfg.radius_m) * float(cfg.radius_m)
	for id in atmo.field.thermals:
		var th: AtmoThermal = atmo.field.thermals[id]
		if th.strength < float(cfg.min_strength_ms) or th.envelope(atmo.time_s) < 0.5:
			continue
		var a := th.axis_at(clampf(eye.y, th.src.y, th.top))
		var d := Vector2(a.x - eye.x, a.y - eye.z).length_squared()
		if d < r2:
			cands.append([d, th])
	cands.sort_custom(func(a, b): return a[0] < b[0])
	_flocks.clear()
	var total := 0
	for i in mini(cands.size(), int(cfg.max_flocks)):
		var th: AtmoThermal = cands[i][1]
		var rng := RandomNumberGenerator.new()
		rng.seed = th.noise_seed
		var n := rng.randi_range(int(cfg.birds_per_flock[0]), int(cfg.birds_per_flock[1]))
		var dir := 1.0 if rng.randf() < 0.5 else -1.0
		var birds: Array = []
		for k in n:
			birds.append(
				Vector4(
					rng.randf() * TAU,
					rng.randf_range(float(cfg.circle_radius_m[0]), float(cfg.circle_radius_m[1])),
					rng.randf(),
					dir
				)
			)
		_flocks.append([th, birds])
		total += n
	_mm.instance_count = total


func _place_birds() -> void:
	var t := atmo.time_s
	var v := float(cfg.speed_ms)
	var band: Array = cfg.altitude_band_m
	var i := 0
	for f in _flocks:
		var th: AtmoThermal = f[0]
		for b: Vector4 in f[1]:
			# Птицы медленно ходят по высоте в полосе band над источником (набирают и сваливаются).
			var y_frac := 0.5 + 0.5 * sin(t * float(cfg.climb_cycle_hz) * TAU + b.x)
			var y := th.src.y + lerpf(float(band[0]), float(band[1]), lerpf(b.z, y_frac, 0.5))
			y = minf(y, th.top - 50.0)
			var axis := th.axis_at(y)
			var w := v / b.y * b.w
			var ang := b.x + w * t
			var pos := Vector3(axis.x + cos(ang) * b.y, y, axis.y + sin(ang) * b.y)
			# Направление полёта — касательная; крен внутрь круга: tg = v²/(g·r).
			var fwd := Vector3(-sin(ang), 0.0, cos(ang)) * b.w
			var bank := atan(v * v / (Units.G * b.y)) * b.w
			var basis := Basis.looking_at(fwd, Vector3.UP).rotated(fwd.normalized(), -bank)
			_mm.set_instance_transform(i, Transform3D(basis, pos))
			var flap := (
				float(cfg.flap_amplitude)
				if fmod(t * 0.1 + b.x, 1.0) < float(cfg.flap_fraction)
				else 0.0
			)
			_mm.set_instance_custom_data(i, Color(b.x / TAU, flap, 0, 0))
			i += 1
