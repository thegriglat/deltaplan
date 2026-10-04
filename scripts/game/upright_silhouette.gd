class_name UprightSilhouette
extends CanvasLayer
## Силуэт стоек трапеции у края кадра (кабина, A3.3 v4): трапеция лежит позади глаз и в кадр при
## взгляде вперёд не попадает, а в жизни стойки видны боковым зрением. Условная замена: когда
## стойка вне кадра, у края кадра с её стороны — тёмная размытая полоса по направлению на стойку
## (проекция, прижатая к краю), прозрачность растёт при приближении стойки к оси взгляда.
## Стойка сама в кадре — не рисуется. Параметры — camera.json → cockpit.silhouette.

const SAMPLES := 41

var rig: CameraRig
var _canvas: Control
var _marks: Array[Array] = []  # [[верх, низ], …] по сторонам: левая, правая
var _head_seen: Node3D
var _draws: Array[Dictionary] = []


func _ready() -> void:
	layer = 0
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)


func _process(_dt: float) -> void:
	_draws.clear()
	var cfg := params()
	if rig != null and rig.mode == "cockpit" and bool(cfg.get("enabled", true)):
		_refresh_marks()
		var size := get_viewport().get_visible_rect().size
		_draws = frame_draws(rig, size.x / maxf(size.y, 1.0), cfg)
	visible = not _draws.is_empty()
	if visible:
		_canvas.queue_redraw()


func params() -> Dictionary:
	return Config.get_config("camera").cockpit.get("silhouette", {})


## Рассчитать силуэты для текущего кадра: по записи на сторону, где стойка вне кадра.
func frame_draws(cam: Camera3D, aspect: float, cfg: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for side in _marks.size():
		var m: Array = _marks[side]
		var d := compute(
			cam.global_transform.affine_inverse(),
			(m[0] as Node3D).global_position,
			(m[1] as Node3D).global_position,
			cam.fov,
			aspect,
			cfg
		)
		if d.draw:
			d.side = side
			out.append(d)
	return out


func _refresh_marks() -> void:
	var h := rig.head
	if h == _head_seen:
		return
	_head_seen = h
	_marks.clear()
	var vis := h.get_parent() as GliderVisual if h != null else null
	if vis == null:
		return
	for s in ["L", "R"]:
		var a := vis.get_marker("UprightTop" + s)
		var b := vis.get_marker("UprightBottom" + s)
		if a != null and b != null:
			_marks.append([a, b])


## Чистая геометрия: cam_inv — мир → камера, a/b — концы оси стойки (мир). Возвращает
## {draw, alpha, edge (0..1 по кадру, y вниз), angle_deg}; draw=false, если часть стойки в кадре.
static func compute(
	cam_inv: Transform3D, a: Vector3, b: Vector3, fov_deg: float, aspect: float, cfg: Dictionary
) -> Dictionary:
	var ty := tan(deg_to_rad(fov_deg) * 0.5)
	var best := 1000.0
	var best_l := Vector3.ZERO
	for i in SAMPLES:
		var l := cam_inv * a.lerp(b, float(i) / (SAMPLES - 1))
		var dep := -l.z
		if dep > 0.04 and absf(l.y) <= dep * ty and absf(l.x) <= dep * ty * aspect:
			return {"draw": false, "alpha": 0.0, "edge": Vector2.ZERO, "angle_deg": 0.0}
		var ang := rad_to_deg(l.angle_to(Vector3(0, 0, -1)))
		if ang < best:
			best = ang
			best_l = l
	var v := Vector2(best_l.x / aspect, -best_l.y)  # экран: высота кадра = 2, y вниз
	if v.length() < 1e-4:
		v = Vector2(0, 1)
	v /= maxf(absf(v.x), absf(v.y))
	var full := float(cfg.get("angle_full_deg", 60.0))
	var zero := float(cfg.get("angle_zero_deg", 150.0))
	var alpha := clampf(inverse_lerp(zero, full, best), 0.0, 1.0) * float(cfg.get("strength", 0.6))
	var edge := Vector2(0.5 + 0.5 * v.x, 0.5 + 0.5 * v.y)
	return {"draw": alpha > 0.0, "alpha": alpha, "edge": edge, "angle_deg": best}


func _on_draw() -> void:
	var cfg := params()
	var sz := _canvas.size
	var depth := float(cfg.get("depth", 0.12)) * sz.y
	var half_len := float(cfg.get("length", 0.35)) * sz.y * 0.5
	var col := Color(0.02, 0.02, 0.03)
	for d in _draws:
		var e: Vector2 = d.edge
		var p := Vector2(e.x * sz.x, e.y * sz.y)
		var on_side := e.x <= 0.001 or e.x >= 0.999
		var pts := PackedVector2Array()
		if on_side:
			var dir := 1.0 if e.x <= 0.001 else -1.0
			var x0 := 0.0 if dir > 0.0 else sz.x
			pts = PackedVector2Array([
				Vector2(x0, p.y - half_len), Vector2(x0, p.y + half_len),
				Vector2(x0 + dir * depth, p.y + half_len * 0.6), Vector2(x0 + dir * depth, p.y - half_len * 0.6)
			])
		else:
			var dir := 1.0 if e.y <= 0.001 else -1.0
			var y0 := 0.0 if dir > 0.0 else sz.y
			pts = PackedVector2Array([
				Vector2(p.x - half_len, y0), Vector2(p.x + half_len, y0),
				Vector2(p.x + half_len * 0.6, y0 + dir * depth), Vector2(p.x - half_len * 0.6, y0 + dir * depth)
			])
		var a: float = d.alpha
		var cols := PackedColorArray([
			Color(col, a), Color(col, a), Color(col, 0.0), Color(col, 0.0)
		])
		_canvas.draw_polygon(pts, cols)
