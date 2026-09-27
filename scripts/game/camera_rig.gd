class_name CameraRig
extends Camera3D
## Камеры (FR-26): из-под крыла (cockpit), сзади (chase), свободная (free).
## Цель — Node3D планера; ориентация берётся из его global_transform.

signal mode_changed(mode: String)

var target: Node3D
var mode := "cockpit"

var _cfg: Dictionary
var _modes: Array
var _head_basis := Basis.IDENTITY
var _orbit := Vector2(0.0, -0.3)  # рыскание, тангаж орбиты
var _free_dist := 15.0
var _orbiting := false
var _head := Vector2.ZERO  # поворот головы: x — рыскание (+ влево), y — тангаж (+ вверх), радианы
var _recentering := false


func _ready() -> void:
	_cfg = Config.get_config("camera")
	_modes = _cfg.modes
	fov = float(_cfg.fov_deg)
	near = float(_cfg.near_m)
	far = float(_cfg.far_m)
	_free_dist = float(_cfg.free.distance_m)
	set_mode(String(_cfg.default_mode))


func set_mode(m: String) -> void:
	mode = m
	mode_changed.emit(mode)


func next_mode() -> void:
	set_mode(_modes[(_modes.find(mode) + 1) % _modes.size()])


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("camera_next"):
		next_mode()
	if event.is_action_pressed("look_center") or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_MIDDLE):
		_recentering = true
	# Обзор мышью (FR-31): в кабине — поворот головы, снаружи — орбита.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and _mouse_looks():
		var k := deg_to_rad(float(Config.value("controls", "mouse.look_sensitivity_deg_per_px")))
		var inv_y := -1.0 if bool(Config.value("controls", "mouse.invert_look_y")) else 1.0
		var d := Vector2(-event.relative.x, -event.relative.y * inv_y) * k
		if mode == "cockpit":
			var h: Dictionary = _cfg.cockpit.head
			_head += d
			_head.x = clampf(_head.x, -deg_to_rad(float(h.yaw_limit_deg)), deg_to_rad(float(h.yaw_limit_deg)))
			_head.y = clampf(_head.y, -deg_to_rad(float(h.pitch_down_limit_deg)), deg_to_rad(float(h.pitch_up_limit_deg)))
			_recentering = false
		else:
			_orbit += d
			_orbit.y = clampf(_orbit.y, -1.5, 1.5)
		return
	if mode != "free":
		return
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
	if target == null:
		return
	var t := target.global_transform
	match mode:
		"cockpit":
			var c: Dictionary = _cfg.cockpit
			var lag := float(c.head_lag_s)
			var k := 1.0 if lag <= 0.0 else 1.0 - exp(-delta / lag)
			_head_basis = _head_basis.slerp(t.basis.orthonormalized(), k).orthonormalized()
			var off: Array = c.offset_m
			global_position = t.origin + t.basis * Vector3(off[0], off[1], off[2])
			if _recentering:
				var rt := float(c.head.recenter_time_s)
				_head = _head.lerp(Vector2.ZERO, 1.0 if rt <= 0.0 else 1.0 - exp(-delta / rt))
				if _head.length() < 0.001:
					_head = Vector2.ZERO
					_recentering = false
			global_basis = _head_basis * Basis(Vector3.UP, _head.x) \
				* Basis(Vector3.RIGHT, _head.y - deg_to_rad(float(c.look_down_deg)))
		"chase":
			var ch: Dictionary = _cfg.chase
			var fwd := -t.basis.z
			fwd.y = 0.0
			fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
			var want := t.origin - fwd * float(ch.distance_m) + Vector3.UP * float(ch.height_m)
			var s := float(ch.smoothing_s)
			var k2 := 1.0 if s <= 0.0 else 1.0 - exp(-delta / s)
			global_position = global_position.lerp(want, k2)
			var ground := _ground_at(global_position)
			global_position.y = maxf(global_position.y, ground + float(ch.min_agl_m))
			look_at(t.origin, Vector3.UP)
		"free":
			var dir := Basis(Vector3.UP, _orbit.x) * Basis(Vector3.RIGHT, _orbit.y) * Vector3.BACK
			global_position = t.origin + dir * _free_dist
			var g := _ground_at(global_position)
			global_position.y = maxf(global_position.y, g + 1.0)
			look_at(t.origin, Vector3.UP)


func _mouse_looks() -> bool:
	return String(Config.value("controls", "mouse.mode")) == "look" or mode != "cockpit"


func _ground_at(p: Vector3) -> float:
	var terrain := get_tree().get_first_node_in_group("terrain")
	if terrain and terrain.has_method("height_at"):
		return terrain.height_at(p.x, p.z)
	return -INF
