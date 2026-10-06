extends Node
## Пробный съёмочный драйвер промо-видео (tools/shots/promo/README.md): без прибора, камера облетает планер по ключам
## [t_с, угол_° (0 — сзади, + вправо, 180 — спереди), радиус_м, высота_м, fov_°], Catmull-Rom между ключами.
## Опорный курс сглажен в мировых осях (tau_heading), позиция камеры — tau_pos, взгляд чуть впереди по курсу.
const MAIN_SCENE := preload("res://scenes/main.tscn")
const KEYS := [
	[0.0, 0.0, 14.0, 3.0, 60.0],
	[4.0, 40.0, 18.0, 4.0, 55.0],
	[8.0, 90.0, 24.0, 3.0, 50.0],
	[12.0, 150.0, 20.0, 5.0, 50.0],
	[16.0, 205.0, 16.0, 3.0, 55.0],
	[19.0, 240.0, 20.0, 4.5, 55.0],
	[22.0, 280.0, 24.0, 5.0, 55.0],
]
const TAU_HEADING := 2.5
const TAU_POS := 0.35
const LOOK_AHEAD_M := 6.0
var _main: Node
var _t0 := -1.0
var _pos := Vector3.ZERO
var _hdg := 0.0
var _look := Vector3.ZERO
func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
func _sample(t: float) -> Array:
	var n := KEYS.size()
	t = clampf(t, KEYS[0][0], KEYS[n - 1][0])
	var i := 0
	while i < n - 2 and t > KEYS[i + 1][0]:
		i += 1
	var a: Array = KEYS[maxi(i - 1, 0)]
	var b: Array = KEYS[i]
	var c: Array = KEYS[i + 1]
	var d: Array = KEYS[mini(i + 2, n - 1)]
	var u := (t - float(b[0])) / (float(c[0]) - float(b[0]))
	var out := []
	for k in range(1, 5):
		var p0 := float(a[k]); var p1 := float(b[k]); var p2 := float(c[k]); var p3 := float(d[k])
		out.append(0.5 * ((2.0 * p1) + (-p0 + p2) * u + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * u * u + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * u * u * u))
	return out
func _process(delta: float) -> void:
	if _main.state != _main.State.FLYING:
		return
	var g = _main.game
	g.overlay.visible = false
	var cam: Camera3D = g.camera
	var tg: Node3D = cam.target
	var fwd := -tg.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var h := atan2(fwd.x, -fwd.z)  # курс, 0 — на север (-Z)
	if _t0 < 0.0:
		_t0 = g.sim_time_s
		cam.process_mode = Node.PROCESS_MODE_DISABLED
		_pos = cam.global_position
		_hdg = h
		_look = tg.global_position
	_hdg = lerp_angle(_hdg, h, 1.0 - exp(-delta / TAU_HEADING))
	var s := _sample(g.sim_time_s - _t0)
	var ang := deg_to_rad(float(s[0]))
	var dir := Vector3(sin(_hdg), 0.0, -cos(_hdg))  # сглаженный курс
	var rot := dir.rotated(Vector3.UP, ang)  # + : камера уходит вправо от планера
	var want := tg.global_position - rot * float(s[1]) + Vector3.UP * float(s[2])
	_pos = _pos.lerp(want, 1.0 - exp(-delta / TAU_POS))
	var ground: float = g.terrain.height_at(_pos.x, _pos.z) + 3.0
	_pos.y = maxf(_pos.y, ground)
	var look_want := tg.global_position + dir * LOOK_AHEAD_M + Vector3.UP * 0.8
	_look = _look.lerp(look_want, 1.0 - exp(-delta / 0.25))
	cam.global_position = _pos
	cam.look_at(_look, Vector3.UP)
	cam.fov = float(s[3])
