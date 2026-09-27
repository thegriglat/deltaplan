class_name Instrument3D
extends Node3D
## Корпус прибора в 3D для кабинного вида: коробка из пластика, экран — текстура SubViewport.
## Экран смотрит в локальную +Z (к пилоту), верх прибора — +Y. Начало координат — центр корпуса.
## Хомут крепления — на задней стенке снизу (к базовой штанге трапеции).
## Размеры и материалы — configs/instruments.json → mount_3d.

var screen_mesh: MeshInstance3D
var _screen_mat: StandardMaterial3D

@onready var instrument: FlightInstrument = $FlightInstrument


func _ready() -> void:
	var cfg: Dictionary = Config.get_config("instruments")
	_build(cfg.get("mount_3d", {}), cfg.get("screen", {}))
	use_instrument(instrument)


## Проброс: данные полёта в прибор.
func update(t: Telemetry, dt: float = -1.0) -> void:
	instrument.update(t, dt)


func set_page(i: int) -> void:
	instrument.set_page(i)


## Показывать экран другого FlightInstrument (один прибор на 3D-корпус и оверлей).
## Свой встроенный прибор при этом отключается, чтобы не рисовать экран дважды.
func use_instrument(fi: FlightInstrument) -> void:
	if fi != instrument and instrument != null:
		instrument.process_mode = Node.PROCESS_MODE_DISABLED
		instrument.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	instrument = fi
	_screen_mat.albedo_texture = fi.get_texture()
	if _screen_mat.emission_enabled:
		_screen_mat.emission_texture = fi.get_texture()


func _build(m: Dictionary, scr: Dictionary) -> void:
	var body_size := _vec3(m.get("body_size_m", [0.105, 0.145, 0.028]))
	var bezel := float(m.get("bezel_m", 0.009))
	var body := MeshInstance3D.new()
	body.name = "Body"
	var box := BoxMesh.new()
	box.size = body_size
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(String(m.get("body_color", "#23262a")))
	body_mat.roughness = 0.6
	box.material = body_mat
	body.mesh = box
	add_child(body)
	# Экран: вписываем в область внутри рамки с пропорциями текстуры.
	var aspect := float(scr.get("width_px", 480)) / float(scr.get("height_px", 640))
	var inner := Vector2(body_size.x - 2.0 * bezel, body_size.y - 2.0 * bezel)
	var sw := minf(inner.x, inner.y * aspect)
	var sh := sw / aspect
	screen_mesh = MeshInstance3D.new()
	screen_mesh.name = "ScreenSurface"
	var quad := QuadMesh.new()
	quad.size = Vector2(sw, sh)
	screen_mesh.mesh = quad
	# Немного выше центра — снизу у реальных приборов кнопки.
	var shift_y := (inner.y - sh) * 0.5
	screen_mesh.position = Vector3(0.0, shift_y, body_size.z * 0.5 + 0.0005)
	_screen_mat = StandardMaterial3D.new()
	_screen_mat.roughness = float(m.get("screen_roughness", 0.35))
	_screen_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	var emission := float(m.get("screen_emission", 0.08))
	if emission > 0.0:
		_screen_mat.emission_enabled = true
		_screen_mat.emission = Color.WHITE
		_screen_mat.emission_energy_multiplier = emission
	quad.material = _screen_mat
	add_child(screen_mesh)
	# Кнопки под экраном (декор).
	var btn_mat := StandardMaterial3D.new()
	btn_mat.albedo_color = body_mat.albedo_color.lightened(0.25)
	var btn_zone := inner.y - sh  # от низа экрана до низа рамки
	for i in 3:
		var b := MeshInstance3D.new()
		var bm := CylinderMesh.new()
		bm.top_radius = minf(bezel, btn_zone) * 0.35 + 0.002
		bm.bottom_radius = bm.top_radius
		bm.height = 0.003
		bm.material = btn_mat
		b.mesh = bm
		b.rotation.x = PI * 0.5
		b.position = Vector3(
			(float(i) - 1.0) * sw * 0.3,
			-inner.y * 0.5 + maxf(btn_zone, 0.0) * 0.5,
			body_size.z * 0.5
		)
		add_child(b)
	# Хомут на задней стенке снизу.
	var clamp_size := _vec3(m.get("clamp_size_m", [0.05, 0.03, 0.03]))
	var clamp := MeshInstance3D.new()
	clamp.name = "Clamp"
	var cb := BoxMesh.new()
	cb.size = clamp_size
	cb.material = body_mat
	clamp.mesh = cb
	clamp.position = Vector3(
		0.0, -body_size.y * 0.5 + clamp_size.y * 0.5, -body_size.z * 0.5 - clamp_size.z * 0.5
	)
	add_child(clamp)


static func _vec3(a: Variant) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ONE * 0.1
