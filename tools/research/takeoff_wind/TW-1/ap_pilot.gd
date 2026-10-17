extends Autopilot
## TW-1, прототип правки автопилота теста — техника старта по Жеглову (1983, с. 108–110) и PD-28
## (docs/research/pendulum/takeoff-ground.md): разбег с трапецией в нейтрали (угол атаки крыла —
## launch.alpha_neutral_deg к потоку, ≈ 0,76 CL_max: отрыв около скорости трима, а не у срыва),
## после отрыва «на себя» pull_bar (доля хода) pull_s секунд — набор скорости у склона, затем трим.
## Срыв на разбеге — «на себя», как у base. Крен и курс — как у base (ПИД маятника).
## Нос держится по положению трапеции (ControlInput.pitch, клавиши с возвратом — InputController).

## Положение трапеции после отрыва, доля хода (−1 — на себя до упора).
var pull_bar := -0.3
## Сколько секунд после отрыва держать pull_bar, с.
var pull_s := 3.0
## Положение трапеции на разбеге (0 — нейтраль).
var run_bar := 0.0
## Допуск положения трапеции, доля хода.
var bar_tol := 0.05
## Выше этой высоты над землёй «на себя» после отрыва больше не держать, м.
var pull_agl_max := 30.0

var _bar := 0.0  ## положение трапеции (последнее известное — из ControlInput через game)
var bar_fn: Callable  ## () -> float: ControlInput.pitch (зовущий подставляет)


func drive(t: Telemetry, dt: float) -> void:
	super.drive(t, dt)
	if bar_fn.is_valid():
		_bar = float(bar_fn.call())
	var want := NAN
	match t.phase:
		"running":
			want = -1.0 if t.stalled else run_bar
		"flying":
			if _air_time < pull_s and t.altitude_agl < pull_agl_max:
				want = pull_bar
	if is_nan(want):
		return
	_press("pitch_pull_in", _bar > want + bar_tol)
	_press("pitch_push_out", _bar < want - bar_tol)
