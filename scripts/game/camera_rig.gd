class_name CameraRig
extends Camera3D
## Камеры (FR-26): из-под крыла (cockpit), сзади (chase), свободная (free).
## Цель — Node3D планера; ориентация берётся из его global_transform.
## Кабинная камера стоит в точке глаз пилота (маркер PilotHead визуала, set_head()).
## Параметры — configs/camera.json. Дальняя плоскость — от мира (SkyEnvironment.setup_camera).

signal mode_changed(mode: String)

## Порядок _process: после планера (он интерполирует своё положение в _process).
const PROCESS_PRIORITY := 10

var target: Node3D
var mode := "cockpit"
## Глаза пилота (маркер PilotHead); null — смещение cockpit.fallback_offset_m от цели.
var head: Node3D
## Высота земли f(x, z) -> м, чтобы внешние камеры не уходили под рельеф.
var ground_fn: Callable = Callable()
## Обзор мышью включён (выключается в меню и на паузе).
var look_enabled := true
## Куда смотреть по клавише «взгляд на прибор» (маркер прибора на трапеции).
var glance_target: Node3D
## Смещение тела пилота от центра (крен/тангаж ручкой) в осях планера, м: () -> Vector3.
## Голова повторяет его долей cockpit.head_follow_body со своим сглаживанием — планшет на
## штанге не «катается» по кадру вместе с телом. Не задано — голова стоит в маркере PilotHead.
var body_shift_fn: Callable = Callable()

var _cfg: Dictionary
var _modes: Array
var _head_basis := Basis.IDENTITY
var _orbit := Vector2(0.0, -0.3)  # рыскание, тангаж орбиты
var _free_dist := 15.0
var _orbiting := false
var _head := Vector2.ZERO  # поворот головы: x — рыскание (+ влево), y — тангаж (+ вверх), радианы
var _recentering := false
var _snap := true
var _glance := 0.0  # 0 — свой взгляд, 1 — на прибор
var _look_locked := false  # голова задана set_look (скриншоты) — мышь её не двигает
var _head_follow := Vector3.ZERO  # сглаженная доля смещения тела, которую повторяет голова


func _ready() -> void:
	process_priority = PROCESS_PRIORITY
	_cfg = Config.get_config("camera")
	_modes = _cfg.modes
	fov = float(_cfg.fov_deg)
	_free_dist = float(_cfg.free.distance_m)
	set_mode(String(_cfg.default_mode))


func set_mode(m: String) -> void:
	if not _modes.has(m):
		push_warning("CameraRig: нет режима камеры '%s'" % m)
		return
	mode = m
	near = float(_cfg.cockpit.near_m) if mode == "cockpit" else float(_cfg.near_m)
	# Шлем и т. п. вокруг глаз — не рисовать из кабины.
	var hidden_bit := 1 << (int(_cfg.cockpit.get("hidden_layer", 20)) - 1)
	cull_mask = (0xFFFFF & ~hidden_bit) if mode == "cockpit" else 0xFFFFF
	_snap = true
	mode_changed.emit(mode)


func next_mode() -> void:
	set_mode(_modes[(_modes.find(mode) + 1) % _modes.size()])


func set_head(n: Node3D) -> void:
	head = n


## Повернуть голову в кабине: рыскание (+ влево) и тангаж (+ вверх), ° (скриншоты, отладка).
## Голова фиксируется: мышь её не двигает до snap() (иначе захваченная мышь сбивает кадр).
func set_look(yaw_deg: float, pitch_deg: float) -> void:
	_head = Vector2(deg_to_rad(yaw_deg), deg_to_rad(pitch_deg))
	_recentering = false
	_look_locked = true


## Сбросить сглаживание (после телепорта планера).
func snap() -> void:
	_snap = true
	_head = Vector2.ZERO
	_look_locked = false


func _unhandled_input(event: InputEvent) -> void:
	if not look_enabled:
		return
	if event.is_action_pressed("camera_next"):
		next_mode()
	var middle_click: bool = (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_MIDDLE
	)
	if event.is_action_pressed("look_center") or middle_click:
		_recentering = true
	# Обзор мышью (FR-31): в кабине — поворот головы, снаружи — орбита.
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and captured and _mouse_looks():
		_look(event.relative)
		return
	if mode == "free":
		_free_input(event)


func _look(rel: Vector2) -> void:
	var k := deg_to_rad(float(Config.value("controls", "mouse.look_sensitivity_deg_per_px")))
	var inv_y := -1.0 if bool(Config.value("controls", "mouse.invert_look_y")) else 1.0
	var d := Vector2(-rel.x, -rel.y * inv_y) * k
	if mode == "cockpit":
		if _look_locked:
			return
		var h: Dictionary = _cfg.cockpit.head
		_head += d
		var yaw_lim := deg_to_rad(float(h.yaw_limit_deg))
		_head.x = clampf(_head.x, -yaw_lim, yaw_lim)
		var down_lim := deg_to_rad(float(h.pitch_down_limit_deg))
		_head.y = clampf(_head.y, -down_lim, deg_to_rad(float(h.pitch_up_limit_deg)))
		_recentering = false
	else:
		_orbit += d
		_orbit.y = clampf(_orbit.y, -1.5, 1.5)


func _free_input(event: InputEvent) -> void:
	var f: Dictionary = _cfg.free
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_free_dist = maxf(float(f.min_distance_m), _free_dist / float(f.zoom_step))
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_free_dist = minf(float(f.max_distance_m), _free_dist * float(f.zoom_step))
	elif event is InputEventMouseMotion and _orbiting:
		_orbit += event.relative * float(f.orbit_sensitivity) * Vector2(-1, -1)
		_orbit.y = clampf(_orbit.y, -1.5, 1.5)


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	var t := target.global_transform
	match mode:
		"cockpit":
			_update_cockpit(t, delta)
		"chase":
			_update_chase(t, delta)
		"free":
			var dir := Basis(Vector3.UP, _orbit.x) * Basis(Vector3.RIGHT, _orbit.y) * Vector3.BACK
			global_position = t.origin + dir * _free_dist
			global_position.y = maxf(global_position.y, _ground_at(global_position) + 1.0)
			look_at(t.origin, Vector3.UP)
	_snap = false


func _update_cockpit(t: Transform3D, delta: float) -> void:
	var c: Dictionary = _cfg.cockpit
	var lag := float(c.head_lag_s)
	var k := 1.0 if lag <= 0.0 or _snap else 1.0 - exp(-delta / lag)
	_head_basis = _head_basis.slerp(_level_head(t.basis, c), k).orthonormalized()
	var eye: Vector3
	if head != null and is_instance_valid(head) and head.is_inside_tree():
		eye = head.global_position + t.basis * (_vec(c.offset_m) + _follow_body(delta, c))
	else:
		eye = t.origin + t.basis * _vec(c.fallback_offset_m)
	global_position = eye
	if _recentering:
		var rt := float(c.head.recenter_time_s)
		_head = _head.lerp(Vector2.ZERO, 1.0 if rt <= 0.0 else 1.0 - exp(-delta / rt))
		if _head.length() < 0.001:
			_head = Vector2.ZERO
			_recentering = false
	var look := _head
	var g: Dictionary = c.get("glance", {})
	var want := 1.0 if look_enabled and Input.is_action_pressed("look_instrument") else 0.0
	var gt := float(g.get("time_s", 0.25))
	_glance = lerpf(_glance, want, 1.0 if gt <= 0.0 else 1.0 - exp(-delta / gt))
	if _glance > 0.001 and glance_target != null and is_instance_valid(glance_target):
		look = look.lerp(_angles_to(glance_target.global_position, eye, c), _glance)
	global_basis = (
		_head_basis
		* Basis(Vector3.UP, look.x)
		* Basis(Vector3.RIGHT, look.y - deg_to_rad(float(c.look_down_deg)))
	)


## Поправка точки глаз в осях планера: маркер PilotHead едет вместе с телом целиком,
## а голова — только долей head_follow_body со своим сглаживанием head_follow_smoothing_s.
func _follow_body(delta: float, c: Dictionary) -> Vector3:
	if not body_shift_fn.is_valid():
		return Vector3.ZERO
	var shift: Vector3 = body_shift_fn.call()
	var want := shift * float(c.get("head_follow_body", 1.0))
	var s := float(c.get("head_follow_smoothing_s", 0.0))
	var k := 1.0 if s <= 0.0 or _snap else 1.0 - exp(-delta / s)
	_head_follow = _head_follow.lerp(want, k)
	return _head_follow - shift


## Голова пилота: курс — вдоль крыла, тангаж — у горизонта, крен — доля крена крыла.
static func _level_head(b: Basis, c: Dictionary) -> Basis:
	var f := -b.z
	f.y = 0.0
	if f.length() < 1e-3:
		f = b.y  # крыло носом вертикально — берём «верх»
		f.y = 0.0
	var yaw := atan2(-f.x, -f.z)
	var bank := -asin(clampf(b.x.normalized().y, -1.0, 1.0))
	var roll := bank * float(c.get("head_roll_follow", 0.5))
	return Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, -roll)


## Поворот головы (рыскание + влево, тангаж + вверх, с учётом look_down), чтобы смотреть на p.
func _angles_to(p: Vector3, eye: Vector3, c: Dictionary) -> Vector2:
	var d := _head_basis.inverse() * (p - eye)
	var yaw := atan2(-d.x, -d.z)
	var pitch := atan2(d.y, Vector2(d.x, d.z).length())
	return Vector2(yaw, pitch + deg_to_rad(float(c.look_down_deg)))


func _update_chase(t: Transform3D, delta: float) -> void:
	var ch: Dictionary = _cfg.chase
	var fwd := -t.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var focus := t.origin + Vector3.UP * float(ch.get("look_height_m", 1.5))
	var want := t.origin - fwd * float(ch.distance_m) + Vector3.UP * float(ch.height_m)
	var s := float(ch.smoothing_s)
	var k := 1.0 if s <= 0.0 or _snap else 1.0 - exp(-delta / s)
	global_position = global_position.lerp(want, k)
	var ground := _ground_at(global_position)
	global_position.y = maxf(global_position.y, ground + float(ch.min_agl_m))
	look_at(focus, Vector3.UP)


func _mouse_looks() -> bool:
	return String(Config.value("controls", "mouse.mode")) == "look" or mode != "cockpit"


func _ground_at(p: Vector3) -> float:
	if ground_fn.is_valid():
		return float(ground_fn.call(p.x, p.z))
	return -INF


static func _vec(a: Variant) -> Vector3:
	var arr: Array = a
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
