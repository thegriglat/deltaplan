class_name DebugOverlays
extends Node
## Отладочные слои (configs/controls.json → debug; в «Управление» не выводятся):
## F1 — производительность простым текстом в левом верхнем углу;
## F2 — подробное меню аддона Debug Menu (графики; создаётся при первом нажатии);
## F5 — ветер вокруг активной камеры: линии-стрелки (свой ArrayMesh) на сетке нескольких высот над землёй;
## F6 — термики: полупрозрачные наклонённые столбы от источника до верха.
## Выключенный слой ничего не считает и не рисует. Воздух — только через публичные функции
## (mean_wind_at, air_velocity_at, time_s, field) — годится для любой модели воздуха.

## Модель воздуха (Atmosphere, CalmAir или другая с mean_wind_at / air_velocity_at).
var air: Node
## Пилот (центр сетки ветра и отбора термиков).
var target: Node3D
## Активная камера: вокруг неё строится сетка стрелок ветра (в любом режиме).
var camera: Node3D
## Высота рельефа (x, z) → м.
var height_fn: Callable

var perf_on := false
var wind_on := false
## F3 (слой WindFieldDebug): состояние сообщает он сам (game.gd подключает сигнал toggled).
var wind_field_on := false
var thermals_on := false

var _cfg: Dictionary = {}
var _period := 1.0 / 3.0

# F1
var _perf_layer: CanvasLayer
var _perf_label: Label
var _perf_t := 0.0
var _perf_n := 0
var _perf_sum := 0.0
var _perf_min := INF
var _perf_max := 0.0
var _cpu_sum := 0.0
var _gpu_sum := 0.0
var _menu: CanvasLayer  ## Debug Menu (аддон), F2

# F5
var _wind_pts: Array[Vector3] = []  ## точки текущего прохода сетки
var _wind_i := 0  ## сколько точек прохода уже нарисовано
var _wind_t := 0.0
var _wind_v := PackedVector3Array()  ## вершины линий текущего прохода
var _wind_c := PackedColorArray()
var _wind_mesh: MeshInstance3D  ## сетка стрелок (обновляется по завершении прохода)
var _wind_pilot: MeshInstance3D  ## крупная стрелка над пилотом (каждый кадр)
var _wind_mat: StandardMaterial3D

# F6
var _th_mesh: MeshInstance3D
var _th_labels: Array[Label3D] = []
var _th_t := 0.0
var _th_mat: StandardMaterial3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_cfg = Config.get_config("controls").get("debug", {})
	InputController.register_actions({"keys": _cfg.get("keys", {})})
	_period = 1.0 / maxf(float(_cfg.get("update_hz", 3.0)), 0.1)
	set_process(false)


func setup(air_node: Node, pilot: Node3D, ground_height: Callable) -> void:
	air = air_node
	target = pilot
	height_fn = ground_height


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey or event is InputEventAction) or not event.is_pressed():
		return
	if event.is_echo():
		return
	for pair: Array in [
		["debug_perf", toggle_perf],
		["debug_menu", toggle_menu],
		["debug_wind", toggle_wind],
		["debug_thermals", toggle_thermals],
	]:
		if InputMap.has_action(pair[0]) and event.is_action_pressed(pair[0]):
			(pair[1] as Callable).call()
			get_viewport().set_input_as_handled()
			return


## Включить слои по именам: perf, wind, thermals (флаг запуска --debug=…).
func enable(names: PackedStringArray) -> void:
	if "perf" in names and not perf_on:
		toggle_perf()
	if "wind" in names and not wind_on:
		toggle_wind()
	if "thermals" in names and not thermals_on:
		toggle_thermals()


func toggle_perf() -> void:
	perf_on = not perf_on
	if perf_on and _perf_layer == null:
		_perf_layer = CanvasLayer.new()
		_perf_layer.layer = 100
		_perf_label = Label.new()
		_perf_label.position = Vector2(12, 8)
		_perf_label.add_theme_font_size_override("font_size", 18)
		_perf_label.add_theme_color_override("font_color", Color(1, 1, 1))
		_perf_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		_perf_label.add_theme_constant_override("outline_size", 5)
		_perf_label.text = "…"
		_perf_layer.add_child(_perf_label)
		add_child(_perf_layer)
	if _perf_layer != null:
		_perf_layer.visible = perf_on
	_perf_reset()
	_set_measure()
	_update_process()


func toggle_menu() -> void:
	if DisplayServer.get_name() == "headless":
		return  # у аддона поток с RenderingServer — без рендера зависает при выходе
	if _menu == null:
		_menu = load("res://addons/debug_menu/debug_menu.tscn").instantiate()
		add_child(_menu)
		_menu.set("style", 2)  # VISIBLE_DETAILED
	else:
		_menu.set("style", 0 if _menu.visible else 2)


func toggle_wind() -> void:
	wind_on = not wind_on
	_wind_pts.clear()
	_wind_i = 0
	_wind_t = _period  # первый проход — сразу
	_wind_v.clear()
	_wind_c.clear()
	if not wind_on:
		for m in [_wind_mesh, _wind_pilot]:
			if m != null:
				(m as MeshInstance3D).queue_free()
		_wind_mesh = null
		_wind_pilot = null
	_update_process()


func toggle_thermals() -> void:
	thermals_on = not thermals_on
	_th_t = _period
	if not thermals_on:
		if _th_mesh != null:
			_th_mesh.queue_free()
			_th_mesh = null
		for l in _th_labels:
			l.queue_free()
		_th_labels.clear()
	_update_process()


func _update_process() -> void:
	set_process(perf_on or wind_on or thermals_on)


func _process(dt: float) -> void:
	if perf_on:
		_perf_frame(dt)
	if wind_on:
		_wind_frame(dt)
	if thermals_on:
		_th_t += dt
		if _th_t >= _period:
			_th_t = 0.0
			_rebuild_thermals()


# ================================================================ F1: производительность


func _set_measure() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var menu_on := _menu != null and _menu.visible
	RenderingServer.viewport_set_measure_render_time(
		get_viewport().get_viewport_rid(), perf_on or menu_on
	)


func _perf_reset() -> void:
	_perf_t = 0.0
	_perf_n = 0
	_perf_sum = 0.0
	_perf_min = INF
	_perf_max = 0.0
	_cpu_sum = 0.0
	_gpu_sum = 0.0


func _perf_frame(dt: float) -> void:
	var rid := get_viewport().get_viewport_rid()
	_perf_n += 1
	_perf_sum += dt
	_perf_min = minf(_perf_min, dt)
	_perf_max = maxf(_perf_max, dt)
	_cpu_sum += (
		RenderingServer.viewport_get_measured_render_time_cpu(rid)
		+ RenderingServer.get_frame_setup_time_cpu()
	)
	_gpu_sum += RenderingServer.viewport_get_measured_render_time_gpu(rid)
	_perf_t += dt
	if _perf_t < 0.5:
		return
	_perf_label.text = perf_text()
	_perf_reset()


## Текст F1 по накопленным кадрам (среднее за ~0,5 с). «Нагрузка» — доля времени кадра, не
## проценты загрузки: настоящую загрузку процессора и видеокарты Godot не сообщает.
## Время скриптов и физики Godot отдаёт только худшим кадром за последнюю секунду.
func perf_text() -> String:
	var n := maxi(_perf_n, 1)
	var frame_ms := _perf_sum / n * 1000.0
	var fps := 1000.0 / maxf(frame_ms, 0.001)
	var render_ms := _cpu_sum / n
	var gpu_ms := _gpu_sum / n
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var share := func(ms: float) -> int: return roundi(ms / maxf(frame_ms, 0.001) * 100.0)
	var hz := 0.0
	if DisplayServer.get_name() != "headless":
		hz = DisplayServer.screen_get_refresh_rate()
	var limit := "CPU (game, physics)"
	if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED and hz > 0.0:
		if fps >= hz * 0.97:
			limit = "V-Sync %d Hz" % roundi(hz)
	if gpu_ms >= frame_ms * 0.85:
		limit = "GPU"
	var lines := PackedStringArray()
	lines.append(
		(
			"FPS %d   frame %.1f ms (%.1f–%.1f)"
			% [roundi(fps), frame_ms, _perf_min * 1000.0, _perf_max * 1000.0]
		)
	)
	lines.append("GPU %.1f ms   %d%% of frame" % [gpu_ms, share.call(gpu_ms)])
	lines.append("CPU render %.1f ms   %d%% of frame" % [render_ms, share.call(render_ms)])
	lines.append(
		"CPU worst in last 1 s: process %.1f ms, physics step %.1f ms" % [proc_ms, phys_ms]
	)
	lines.append("limit: " + limit)
	var calls := roundi(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objs := roundi(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var vram := roundi(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0)
	lines.append("draw calls %d   objects %d   VRAM %d MB" % [calls, objs, vram])
	return "\n".join(lines)


# ================================================================ F5: ветер


## Средний воздух в точке: горизонталь — mean_wind_at, вертикаль — поток без пульсаций
## (склон, подветренная, термики), если модель умеет выключать турбулентность.
func mean_air_at(pos: Vector3) -> Vector3:
	var v: Vector3 = air.call("mean_wind_at", pos)
	if absf(v.y) < 1.0e-6 and "turbulence_enabled" in air:
		var was: bool = air.get("turbulence_enabled")
		air.set("turbulence_enabled", false)
		v.y = (air.call("air_velocity_at", pos) as Vector3).y
		air.set("turbulence_enabled", was)
	return v


## Цвет по вертикали: синий — опускание, серый — ~0, красный — подъём.
func w_color(w: float) -> Color:
	var k := clampf(w / maxf(float(_cfg.get("wind_w_full_ms", 2.0)), 0.1), -1.0, 1.0)
	var grey := Color(0.75, 0.75, 0.75)
	if k >= 0.0:
		return grey.lerp(Color(1.0, 0.15, 0.1), k)
	return grey.lerp(Color(0.1, 0.35, 1.0), -k)


func _wind_grid() -> Array[Vector3]:
	var out: Array[Vector3] = []
	var center_node: Node3D = camera if camera != null else target
	if center_node == null or not height_fn.is_valid():
		return out
	var r := float(_cfg.get("wind_radius_m", 1800.0))
	var step := maxf(float(_cfg.get("wind_step_m", 150.0)), 20.0)
	var p := center_node.global_position
	var cx := roundf(p.x / step) * step
	var cz := roundf(p.z / step) * step
	var n := int(r / step)
	var heights: Array = _cfg.get("wind_heights_agl_m", [20.0, 100.0, 300.0])
	for i in range(-n, n + 1):
		for j in range(-n, n + 1):
			if i * i + j * j > n * n:
				continue
			var x := cx + i * step
			var z := cz + j * step
			var g := float(height_fn.call(x, z))
			for h: float in heights:
				out.append(Vector3(x, g + h, z))
	return out


## Линии стрелки from→to: древко и четыре «уса» наконечника (долей длины, не длиннее head_m).
static func arrow_lines(
	from: Vector3, to: Vector3, col: Color, head_m: float, verts: PackedVector3Array,
	cols: PackedColorArray
) -> void:
	var d := to - from
	var len := d.length()
	if len < 1.0e-4:
		return
	var dir := d / len
	var ref := Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT
	var s1 := dir.cross(ref).normalized()
	var s2 := dir.cross(s1)
	var h := minf(head_m, len * 0.4)
	var back := to - dir * h
	verts.append(from)
	verts.append(to)
	for side: Vector3 in [s1, -s1, s2, -s2]:
		verts.append(to)
		verts.append(back + side * h * 0.35)
	for _i in 10:
		cols.append(col)


func _wind_material() -> StandardMaterial3D:
	if _wind_mat == null:
		_wind_mat = StandardMaterial3D.new()
		_wind_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_wind_mat.vertex_color_use_as_albedo = true
		_wind_mat.disable_fog = true
	return _wind_mat


func _lines_mesh(verts: PackedVector3Array, cols: PackedColorArray) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	mesh.surface_set_material(0, _wind_material())
	return mesh


func _wind_instance() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.top_level = true
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


## Сетку считаем по частям каждый кадр (проход — за _period); готовая сетка подменяется целиком
## по окончании прохода: стрелка живёт до следующего прохода, рывка на кадре обновления нет.
func _wind_frame(dt: float) -> void:
	if air == null:
		return
	_wind_t += dt
	if _wind_i >= _wind_pts.size() and _wind_t >= _period:
		_wind_t = 0.0
		_wind_pts = _wind_grid()
		_wind_i = 0
		_wind_v.clear()
		_wind_c.clear()
	var arrow_s := float(_cfg.get("wind_arrow_s", 6.0))
	var frames := maxf(_period / maxf(dt, 0.001), 1.0)
	var chunk := ceili(_wind_pts.size() / frames)
	if chunk > 0 and _wind_i < _wind_pts.size():
		var end := mini(_wind_i + chunk, _wind_pts.size())
		for k in range(_wind_i, end):
			var pos := _wind_pts[k]
			var v := mean_air_at(pos)
			if v.length() < 0.05:
				continue
			arrow_lines(pos, pos + v * arrow_s, w_color(v.y), 0.25 * v.length() * arrow_s, _wind_v, _wind_c)
		_wind_i = end
		if _wind_i >= _wind_pts.size():
			if _wind_mesh == null:
				_wind_mesh = _wind_instance()
			_wind_mesh.mesh = _lines_mesh(_wind_v, _wind_c)
	# Фактический воздух у пилота (с пульсациями) — крупная стрелка над ним, каждый кадр.
	if target != null and target.is_visible_in_tree():
		var p := target.global_position + Vector3(0, 6, 0)
		var va: Vector3 = air.call("air_velocity_at", p)
		var pv := PackedVector3Array()
		var pc := PackedColorArray()
		arrow_lines(p, p + va * 0.8, Color(1.0, 0.9, 0.2), 0.3 * va.length() * 0.8, pv, pc)
		if _wind_pilot == null:
			_wind_pilot = _wind_instance()
		_wind_pilot.mesh = _lines_mesh(pv, pc)


# ================================================================ F6: термики


## Сила → цвет: слабые — зелёные, 2–3 м/с — жёлтые, от 5 м/с — красные.
static func strength_color(w: float) -> Color:
	var k := clampf(w / 5.0, 0.0, 1.0)
	if k < 0.45:
		return Color(0.15, 0.9, 0.25).lerp(Color(1.0, 0.85, 0.0), k / 0.45)
	return Color(1.0, 0.85, 0.0).lerp(Color(1.0, 0.1, 0.05), (k - 0.45) / 0.55)


## Термики для слоя: [{axis0, axis1 (низ/верх оси), y0, y1, r0 (у верха), strength, id}].
## Считается по полям AtmoThermal на время атмосферы, модель не трогает.
func thermal_shapes() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if air == null or target == null or not ("field" in air):
		return out
	var field: Object = air.get("field")
	if field == null or not ("thermals" in field):
		return out
	var t := float(air.get("time_s")) if "time_s" in air else 0.0
	var p := target.global_position
	var rmax := float(_cfg.get("thermal_radius_m", 8000.0))
	var rmin := float(field.get("_rmin")) if "_rmin" in field else 0.45
	for th: AtmoThermal in (field.get("thermals") as Dictionary).values():
		var env := th.envelope(t)
		if env < 0.02 or (not th.is_static and t > th.t_end()):
			continue
		var d := th.drift_at(t)
		var u := th.decay_progress(t)
		var y0 := th.src.y + (th.top - th.src.y) * u
		var y1 := th.top
		if y1 - y0 < 5.0:
			continue
		var a0 := Vector2(th.src.x, th.src.z) + th.lean * (y0 - th.src.y) + d
		if a0.distance_to(Vector2(p.x, p.z)) > rmax:
			continue
		(
			out
			. append(
				{
					"id": th.id,
					"src": th.src + Vector3(d.x, 0.0, d.y),
					"lean": th.lean,
					"y0": y0,
					"y1": y1,
					"r": th.radius,
					"rmin": rmin,
					"strength": th.strength * env,
				}
			)
		)
	return out


## Радиус ядра на высоте y (как ThermalField.sample: Allen, от rmin у земли до r у верха).
static func core_radius(s: Dictionary, y: float) -> float:
	var span := maxf(float(s.y1) - float(s.src.y), 1.0)
	var xi := clampf((y - float(s.src.y)) / span, 0.0, 1.0)
	var rf := maxf(float(s.rmin), pow(xi, 1.0 / 3.0) * (1.0 - 0.25 * xi) / 0.75)
	return float(s.r) * rf


func _rebuild_thermals() -> void:
	var shapes := thermal_shapes()
	if _th_mesh == null:
		_th_mesh = MeshInstance3D.new()
		_th_mesh.top_level = true
		_th_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_th_mesh)
	_material()
	var mesh := ArrayMesh.new()
	const SECTIONS := 8
	const SEG := 16
	const MID := 4
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var lverts := PackedVector3Array()
	var lcols := PackedColorArray()
	for s in shapes:
		var c: Color = strength_color(float(s.strength))
		var fill := Color(c, 0.28)
		var edge := Color(c, 0.9)
		var base := verts.size()
		for k in SECTIONS + 1:
			var y := lerpf(float(s.y0), float(s.y1), float(k) / SECTIONS)
			var dh := y - float(s.src.y)
			var ax := Vector2(s.src.x, s.src.z) + (s.lean as Vector2) * dh
			var r := core_radius(s, y)
			for m in SEG:
				var ang := TAU * m / SEG
				var v := Vector3(ax.x + cos(ang) * r, y, ax.y + sin(ang) * r)
				verts.append(v)
				cols.append(fill)
				# Контур края: кольца низа, верха и середины.
				if k == 0 or k == SECTIONS or k == MID:
					var ang2 := TAU * (m + 1) / SEG
					lverts.append(v)
					lverts.append(Vector3(ax.x + cos(ang2) * r, y, ax.y + sin(ang2) * r))
					lcols.append(edge)
					lcols.append(edge)
		for k in SECTIONS:
			for m in SEG:
				var a := base + k * SEG + m
				var b := base + k * SEG + (m + 1) % SEG
				idx.append_array([a, a + SEG, b, b, a + SEG, b + SEG])
	if not verts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_COLOR] = cols
		arr[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(0, _th_mat)
		var larr := []
		larr.resize(Mesh.ARRAY_MAX)
		larr[Mesh.ARRAY_VERTEX] = lverts
		larr[Mesh.ARRAY_COLOR] = lcols
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, larr)
		mesh.surface_set_material(1, _th_mat)
	_th_mesh.mesh = mesh
	_update_labels(shapes)


func _material() -> StandardMaterial3D:
	if _th_mat != null:
		return _th_mat
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_fog = true
	_th_mat = m
	return m


func _update_labels(shapes: Array[Dictionary]) -> void:
	while _th_labels.size() < shapes.size():
		var l := Label3D.new()
		l.top_level = true
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.fixed_size = true
		l.pixel_size = 0.0012
		l.font_size = 28
		l.outline_size = 8
		l.no_depth_test = true
		add_child(l)
		_th_labels.append(l)
	for i in _th_labels.size():
		var l := _th_labels[i]
		l.visible = i < shapes.size()
		if not l.visible:
			continue
		var s := shapes[i]
		var dh := float(s.y1) - float(s.src.y)
		var ax := Vector2(s.src.x, s.src.z) + (s.lean as Vector2) * dh
		l.position = Vector3(ax.x, float(s.y1) + 20.0, ax.y)
		l.text = "%.1f m/s" % float(s.strength)
		l.modulate = strength_color(float(s.strength))
