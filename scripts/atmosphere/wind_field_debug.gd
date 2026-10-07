class_name WindFieldDebug
extends Node3D
## Отладочные стрелки ветра (AM-10, docs/archive/plan/wind-field.md → «Ответы пользователя» п. 4): по F3 — сетка
## стрелок горизонтального ветра вокруг пилота на нескольких высотах, цвет — вертикальная
## составляющая (подъём/опускание); повторное F3 — выключить. Выключено — ничего не считается и
## не рисуется (_process выключен, MultiMesh скрыт): ноль влияния на FPS.
## Ветер берётся из Atmosphere.air_velocity_at (уже сочетает поле AM-05 и аналитику — тот же
## вызов, что видит пилот); подпись режима — Atmosphere.is_air_field_on().
## Узел — сцена, не игровая логика: в game.tscn как самостоятельный ребёнок Game, ссылки на
## Air/Glider/Terrain берутся по имени (get_node), поэтому game.gd трогать не нужно.
## F4 — слой «карта фаз» (air-phase P12): клетки области 400 м цветом главной фазы (наибольший вес
## AirRuntime.phase_map.weights), точка — пилот; текстура ny×nx собирается один раз на новое поле.

## Цвета фаз A, B, C, D, F, G, H (порядок AirPhase.PHASES) и подписи легенды.
const PHASE_COLORS := {
	"A": Color(0.3, 0.8, 0.3),
	"B": Color(0.95, 0.85, 0.2),
	"C": Color(0.3, 0.6, 1.0),
	"D": Color(0.6, 0.35, 0.15),
	"F": Color(1.0, 0.4, 0.2),
	"G": Color(0.55, 0.3, 0.8),
	"H": Color(0.6, 0.6, 0.6),
}
## Сторона карты на экране, пикс.
@export var phase_map_px: float = 288.0

## Радиус сетки вокруг пилота, м.
@export var radius_m: float = 1000.0
## Шаг сетки, м.
@export var spacing_m: float = 200.0
## Высоты над рельефом, м (несколько уровней).
@export var levels_agl: PackedFloat32Array = [20.0, 100.0, 300.0]
## Как часто пересчитывать стрелки, пока включено, с.
@export var update_interval_s: float = 0.25
## Длина стрелки на максимальной скорости шкалы, м.
@export var arrow_len_m: float = 90.0
## Скорость горизонтали, на которой стрелка — полной длины, м/с.
@export var speed_scale_ms: float = 12.0
## Толщина стрелки, м.
@export var arrow_thick_m: float = 14.0
## Вертикаль, на которой цвет насыщен (подъём/опускание), м/с.
@export var w_scale_ms: float = 2.5

var _active: bool = false
var _timer: float = 1.0e9
var _mm: MultiMeshInstance3D
var _label: Label
var _canvas: CanvasLayer
var _air: Node
var _glider: Node3D
var _terrain: Node
var _grid_center := Vector2.INF
var _phase_on := false
var _phase_canvas: CanvasLayer
var _phase_rect: TextureRect
var _phase_dot: ColorRect
var _phase_label: Label
var _phase_src: Variant = null


func _ready() -> void:
	set_process(false)
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_F3:
			_toggle()
			get_viewport().set_input_as_handled()
		elif (event as InputEventKey).keycode == KEY_F4:
			_toggle_phase()
			get_viewport().set_input_as_handled()


func _toggle() -> void:
	_active = not _active
	set_process(_active or _phase_on)
	if _active:
		if not _resolve_refs():
			_active = false
			set_process(_phase_on)
			return
		_ensure_visual()
		_mm.visible = true
		_canvas.visible = true
		_timer = 1.0e9
		_process(0.0)
	else:
		if _mm != null:
			_mm.visible = false
		if _canvas != null:
			_canvas.visible = false


func _toggle_phase() -> void:
	_phase_on = not _phase_on
	if _phase_on:
		_resolve_refs()
		_ensure_phase_ui()
		_phase_src = null
		_update_phase()
	if _phase_canvas != null:
		_phase_canvas.visible = _phase_on
	set_process(_active or _phase_on)


func _ensure_phase_ui() -> void:
	if _phase_canvas != null:
		return
	_phase_canvas = CanvasLayer.new()
	_phase_canvas.name = "PhaseMapUi"
	add_child(_phase_canvas)
	_phase_rect = TextureRect.new()
	_phase_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_phase_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_phase_rect.position = Vector2(12, 40)
	_phase_rect.size = Vector2(phase_map_px, phase_map_px)
	_phase_canvas.add_child(_phase_rect)
	_phase_dot = ColorRect.new()
	_phase_dot.color = Color.WHITE
	_phase_dot.size = Vector2(6, 6)
	_phase_canvas.add_child(_phase_dot)
	_phase_label = Label.new()
	_phase_label.position = Vector2(12, 44 + phase_map_px)
	_phase_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_phase_label.add_theme_constant_override("outline_size", 3)
	_phase_canvas.add_child(_phase_label)


## Карта фаз из AirRuntime: текстура — при новой карте, точка пилота — каждый раз.
func _update_phase() -> void:
	var rt := get_node_or_null("../AirRuntime")
	var pm: Dictionary = rt.get("phase_map") if rt != null else {}
	if pm.is_empty():
		_phase_rect.texture = null
		_phase_dot.visible = false
		_phase_label.text = "F4 — карта фаз: нет (поле без фаз)"
		return
	var w: PackedFloat32Array = pm.weights
	if not is_same(_phase_src, w):
		_phase_src = w
		_phase_rect.texture = ImageTexture.create_from_image(phase_image(pm))
		var legend: PackedStringArray = []
		for nm: String in pm.phases:
			legend.append(nm)
		_phase_label.text = "F4 — карта фаз: " + " ".join(legend)
	_phase_dot.visible = _glider != null and is_instance_valid(_glider)
	if _phase_dot.visible:
		var p := _glider.global_position
		var span := float(pm.dx) * Vector2(float(pm.nx), float(pm.ny))
		var uv := Vector2((p.x - float(pm.x0)) / span.x, (-p.z - float(pm.y0)) / span.y)
		# север (+y мира) — вверх карты
		var px := Vector2(uv.x, 1.0 - uv.y).clamp(Vector2.ZERO, Vector2.ONE) * phase_map_px
		_phase_dot.position = _phase_rect.position + px - _phase_dot.size * 0.5


## Изображение ny×nx: цвет фазы с наибольшим весом (север вверху).
static func phase_image(pm: Dictionary) -> Image:
	var nx := int(pm.nx)
	var ny := int(pm.ny)
	var w: PackedFloat32Array = pm.weights
	var names: Array = pm.phases
	var kk := names.size()
	var img := Image.create(nx, ny, false, Image.FORMAT_RGB8)
	for j in ny:
		for i in nx:
			var q := j * nx + i
			var best := 0
			for k in range(1, kk):
				if w[k * nx * ny + q] > w[best * nx * ny + q]:
					best = k
			var col: Color = PHASE_COLORS.get(names[best] if kk > 0 else "", Color.BLACK)
			img.set_pixel(i, ny - 1 - j, col)
	return img


func _resolve_refs() -> bool:
	if _air == null:
		_air = get_node_or_null("../Air")
	if _glider == null:
		_glider = get_node_or_null("../Glider") as Node3D
	if _terrain == null:
		_terrain = get_node_or_null("../Terrain")
	return (
		_air != null
		and _glider != null
		and _air.has_method("air_velocity_at")
		and _terrain != null
		and _terrain.has_method("height_at")
	)


func _process(delta: float) -> void:
	_timer += delta
	if _timer < update_interval_s:
		return
	_timer = 0.0
	if _phase_on:
		_update_phase()
	if not _active or not is_instance_valid(_glider) or not is_instance_valid(_air):
		return
	_rebuild()


func _ensure_visual() -> void:
	if _mm == null:
		_mm = MultiMeshInstance3D.new()
		_mm.name = "Arrows"
		_mm.multimesh = MultiMesh.new()
		_mm.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		_mm.multimesh.use_colors = true
		_mm.multimesh.mesh = _build_arrow_mesh()
		_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_mm.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mm.material_override = mat
		add_child(_mm)
	if _canvas == null:
		_canvas = CanvasLayer.new()
		_canvas.name = "WindFieldDebugUi"
		add_child(_canvas)
		_label = Label.new()
		_label.name = "Mode"
		_label.position = Vector2(12, 12)
		_label.add_theme_color_override("font_color", Color.WHITE)
		_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_label.add_theme_constant_override("outline_size", 3)
		_canvas.add_child(_label)


func _rebuild() -> void:
	var origin: Vector3 = _glider.global_position
	var n := maxi(1, int(round(radius_m / spacing_m)))
	var count := (2 * n + 1) * (2 * n + 1) * levels_agl.size()
	if _mm.multimesh.instance_count != count:
		_mm.multimesh.instance_count = count
	var idx := 0
	for lvl in levels_agl.size():
		var agl := levels_agl[lvl]
		for jy in range(-n, n + 1):
			for ix in range(-n, n + 1):
				var x := origin.x + ix * spacing_m
				var z := origin.z + jy * spacing_m
				var gh := float(_terrain.call("height_at", x, z))
				var pos := Vector3(x, gh + agl, z)
				var v: Vector3 = _air.call("air_velocity_at", pos)
				var h := Vector2(v.x, v.z)
				var speed := h.length()
				var dir := h / speed if speed > 0.05 else Vector2(1.0, 0.0)
				var len_m := arrow_len_m * clampf(speed / speed_scale_ms, 0.15, 1.0)
				var fwd := Vector3(dir.x, 0.0, dir.y)
				var right := fwd.cross(Vector3.UP)
				if right.length_squared() < 1.0e-6:
					right = Vector3.RIGHT
				right = right.normalized()
				var up := right.cross(fwd).normalized()
				var basis := Basis(right, up, fwd).scaled(
					Vector3(arrow_thick_m, arrow_thick_m, len_m)
				)
				_mm.multimesh.set_instance_transform(idx, Transform3D(basis, pos))
				_mm.multimesh.set_instance_color(idx, _w_color(v.y))
				idx += 1
	_grid_center = Vector2(origin.x, origin.z)
	if _label != null:
		var on := bool(_air.call("is_air_field_on")) if _air.has_method("is_air_field_on") else false
		_label.text = "F3 — ветер: %s" % ("поле" if on else "аналитика")


func _w_color(w: float) -> Color:
	var t := clampf(w / w_scale_ms, -1.0, 1.0)
	if t >= 0.0:
		return Color(1.0, 1.0, 1.0).lerp(Color(1.0, 0.15, 0.1), t)  # подъём — красный, как F5
	return Color(1.0, 1.0, 1.0).lerp(Color(0.1, 0.35, 1.0), -t)  # опускание — синий


## Стрелка вдоль локального +Z, единичной длины (масштаб — в transform экземпляра).
static func _build_arrow_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var shaft_r := 0.06
	var shaft_len := 0.65
	var head_r := 0.16
	var head_len := 0.35
	var segs := 6
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var p00 := Vector3(cos(a0) * shaft_r, sin(a0) * shaft_r, 0.0)
		var p01 := Vector3(cos(a1) * shaft_r, sin(a1) * shaft_r, 0.0)
		var p10 := Vector3(cos(a0) * shaft_r, sin(a0) * shaft_r, shaft_len)
		var p11 := Vector3(cos(a1) * shaft_r, sin(a1) * shaft_r, shaft_len)
		st.add_vertex(p00)
		st.add_vertex(p10)
		st.add_vertex(p01)
		st.add_vertex(p01)
		st.add_vertex(p10)
		st.add_vertex(p11)
	var tip := Vector3(0.0, 0.0, shaft_len + head_len)
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var p0 := Vector3(cos(a0) * head_r, sin(a0) * head_r, shaft_len)
		var p1 := Vector3(cos(a1) * head_r, sin(a1) * head_r, shaft_len)
		st.add_vertex(p0)
		st.add_vertex(tip)
		st.add_vertex(p1)
	st.generate_normals()
	return st.commit()
