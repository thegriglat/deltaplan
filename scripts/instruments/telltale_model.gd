class_name TelltaleModel
extends RefCounted
## Ленточка на тросе трапеции (docs/telltale.md): цепочка из N отрезков, каждый — единичное
## направление в мировых осях от узла к хвосту. Без нод, тестируется headless.
##
## Каждый отрезок стремится к равновесию «сопротивление ткани + вес»: f = ŵ·(|w|/v45)² + вниз,
## где w — поток воздуха относительно точки крепления (ветер − скорость точки), v45 — поток, при
## котором ленточка поднимается на 45° (instruments.json → telltale.lift_45_ms). Приближение —
## экспоненциальное (безусловно устойчиво при любом шаге): скорость подстройки растёт с потоком
## (ткань «сносит» потоком за время длины отрезка) плюс маятниковая при безветрии. Хвост догоняет
## предыдущий отрезок (волна вдоль ленточки), трепет — бегущая синусоида, растёт со скоростью.

const DOWN := Vector3.DOWN

var dirs: Array[Vector3] = []  ## направления отрезков (мир), от узла к хвосту
var segment_m := 0.06
var flutter_angle := 0.0  ## текущая амплитуда трепета, рад (для отладки/кадров)
var time_s := 0.0
var lateral := Vector3.RIGHT  ## ось трепета (поперёк потока, горизонтально), мир

var _v45 := 1.0
var _follow := 1.0
var _pendulum := 6.0
var _coupling := 0.5
var _fl_start := 2.0
var _fl_full := 15.0
var _fl_max := 0.3
var _fl_hz_per_ms := 0.5
var _fl_max_hz := 9.0
var _fl_wave := 0.9
var _max_flow := 60.0
var _phase := 0.0
var _phase2 := 0.0

## cfg — instruments.json → telltale.
func setup(cfg: Dictionary) -> void:
	var n := maxi(int(cfg.get("segments", 5)), 1)
	segment_m = float(cfg.get("length_m", 0.13)) / n
	_v45 = maxf(float(cfg.get("lift_45_ms", 1.0)), 0.05)
	_follow = float(cfg.get("follow_k", 1.0))
	_pendulum = float(cfg.get("pendulum_rate_per_s", 6.0))
	_coupling = clampf(float(cfg.get("chain_coupling", 0.5)), 0.0, 0.95)
	_fl_start = float(cfg.get("flutter_start_ms", 2.0))
	_fl_full = maxf(float(cfg.get("flutter_full_ms", 15.0)), _fl_start + 0.01)
	_fl_max = deg_to_rad(float(cfg.get("flutter_max_deg", 18.0)))
	_fl_hz_per_ms = float(cfg.get("flutter_hz_per_ms", 0.5))
	_fl_max_hz = float(cfg.get("flutter_max_hz", 9.0))
	_fl_wave = float(cfg.get("flutter_wave_rad_per_segment", 0.9))
	_max_flow = float(cfg.get("max_airflow_ms", 60.0))
	dirs.clear()
	for i in n:
		dirs.append(DOWN)
	_phase = randf() * TAU
	_phase2 = randf() * TAU


## Поставить ленточку сразу в равновесие для потока w (после телепорта, на старте).
func snap(w: Vector3) -> void:
	var t := equilibrium(w)
	for i in dirs.size():
		dirs[i] = t


## Равновесное направление ленточки без трепета для потока w (мир), единичный вектор.
func equilibrium(w: Vector3) -> Vector3:
	var s := minf(w.length(), _max_flow)
	if s < 1.0e-4:
		return DOWN
	var f := w / w.length() * (s * s / (_v45 * _v45)) + DOWN
	return f.normalized() if f.length() > 1.0e-6 else DOWN


## Шаг: w — поток воздуха относительно точки крепления (мир), м/с.
func step(dt: float, w: Vector3) -> void:
	time_s += dt
	var s := minf(w.length(), _max_flow)
	var target := equilibrium(w)
	# ось трепета: горизонтально поперёк потока (при вертикальном потоке — прежняя)
	var lat := w.cross(Vector3.UP)
	if lat.length() > 1.0e-3:
		lateral = lat.normalized()
	var fl_amp := _fl_max * smoothstep(_fl_start, _fl_full, s)
	flutter_angle = fl_amp
	var hz := minf(_fl_hz_per_ms * s, _fl_max_hz)
	_phase = fposmod(_phase + TAU * hz * dt, TAU)
	_phase2 = fposmod(_phase2 + TAU * hz * 0.61 * dt, TAU)
	var rate := _follow * s / segment_m + _pendulum
	var k := 1.0 - exp(-rate * dt)
	var n := dirs.size()
	var up_axis := target.cross(lateral)
	up_axis = up_axis.normalized() if up_axis.length() > 1.0e-3 else Vector3.UP
	for i in n:
		var t := target
		if fl_amp > 0.0:
			var tip := float(i + 1) / n
			var a := fl_amp * tip * sin(_phase - _fl_wave * i)
			var b := 0.35 * fl_amp * tip * sin(_phase2 - 0.7 * _fl_wave * i)
			t = t.rotated(up_axis, a)
			if lateral.cross(t).length() > 1.0e-3:
				t = t.rotated(lateral.cross(t).normalized(), b)
		if i > 0:
			t = t.lerp(dirs[i - 1], _coupling)
			t = t.normalized() if t.length() > 1.0e-6 else target
		var d := dirs[i].lerp(t, k)
		dirs[i] = d.normalized() if d.length() > 1.0e-6 else t


## Средняя линия ленточки: узел → хвост, единичный вектор (мир).
func direction() -> Vector3:
	var sum := Vector3.ZERO
	for d in dirs:
		sum += d
	return sum.normalized() if sum.length() > 1.0e-6 else DOWN


## Поток воздуха относительно точки крепления r (оси планера, от начала ноды планера):
## ветер air минус скорость точки = скорость начала + вращение (по смене ориентации за шаг).
static func airflow_at(
	air: Vector3, velocity: Vector3, prev_basis: Basis, cur_basis: Basis, r: Vector3, dt: float
) -> Vector3:
	var v_rot := (cur_basis * r - prev_basis * r) / dt if dt > 0.0 else Vector3.ZERO
	return air - velocity - v_rot
