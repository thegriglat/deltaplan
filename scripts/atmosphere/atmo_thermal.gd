class_name AtmoThermal
extends RefCounted
## Один термик: наклонённый ветром столб от источника на земле до верха (кромки облаков).
## Параметры задаёт ThermalField при рождении; зависящие от времени величины
## (огибающая, отрыв низа, снос) обновляются в update_time() — раз за шаг физики.

var id: int = 0
var is_static: bool = false
var noise_seed: int = 0

## Источник: x, высота земли в источнике, z (мир).
var src: Vector3 = Vector3.ZERO
## Верх столба над уровнем моря, м (обычно = кромка облаков).
var top: float = 0.0
## Сила ядра на пике, м/с.
var strength: float = 0.0
## Радиус ядра у верха, м.
var radius: float = 100.0
## Наклон оси: горизонтальное смещение (x, z) на 1 м подъёма.
var lean: Vector2 = Vector2.ZERO
## Скорость сноса термика ветром, м/с (x, z).
var drift_vel: Vector2 = Vector2.ZERO
## Через сколько секунд после рождения термик отрывается от источника и уходит с ветром целиком
## (пузырь/колонна дрейфует с воздухом, VR-0). < 0 — сносится только на распаде.
var drift_delay: float = -1.0

## Времена жизни, с (время атмосферы).
var t_birth: float = 0.0
var t_grow: float = 1.0
var t_mature: float = 1.0
var t_decay: float = 1.0

## Облако: есть ли, мощность (м), вытянутость по ветру (≥ 1), переразвитие (0..1).
var has_cloud: bool = false
var cloud_depth: float = 0.0
var cloud_stretch: float = 1.0
var overdevelop: float = 0.0
## Кучево-дождевое (Cb): мощная башня до тропопаузы, наковальня, ливневый нисходящий поток.
var is_cb: bool = false
## Усиление подъёма под основанием (облачный подсос) 0..; у Cb > 0.
var suck: float = 0.0

## --- Состояние на текущий момент (update_time) ---
var env: float = 0.0  ## огибающая силы 0..1
var cut_h: float = -1.0e9  ## ниже этой высоты подъёма нет (оторвавшийся низ)
var drift: Vector2 = Vector2.ZERO  ## текущее смещение от сноса, м


func t_end() -> float:
	return t_birth + t_grow + t_mature + t_decay


func t_decay_start() -> float:
	return t_birth + t_grow + t_mature


## Доля распада 0..1 в момент t.
## Момент, с которого термик (и облако над ним) сносится ветром.
func drift_start() -> float:
	if drift_delay >= 0.0:
		return t_birth + drift_delay
	return t_decay_start()


## Смещение сносом в момент t (снос продолжается и после конца термика, пока облако тает).
func drift_at(t: float) -> Vector2:
	if is_static:
		return Vector2.ZERO
	return drift_vel * maxf(0.0, t - drift_start())


func decay_progress(t: float) -> float:
	if is_static:
		return 0.0
	return clampf((t - t_decay_start()) / maxf(t_decay, 0.001), 0.0, 1.0)


## Огибающая силы: рост → зрелость → распад.
func envelope(t: float) -> float:
	if is_static:
		return 1.0
	var a := t - t_birth
	if a <= 0.0:
		return 0.0
	if a < t_grow:
		return smoothstep(0.0, t_grow, a)
	var u := decay_progress(t)
	return 1.0 - smoothstep(0.0, 1.0, u)


func update_time(t: float) -> void:
	if is_static:
		env = 1.0
		cut_h = -1.0e9
		drift = Vector2.ZERO
		return
	# То же, что envelope()/decay_progress(), но без лишних вызовов — зовётся часто.
	var a := t - t_birth
	var ds := t_grow + t_mature
	if a <= 0.0:
		env = 0.0
	elif a < t_grow:
		env = smoothstep(0.0, t_grow, a)
	else:
		env = 1.0
	if a > ds:
		var u := minf((a - ds) / maxf(t_decay, 0.001), 1.0)
		env = 1.0 - smoothstep(0.0, 1.0, u)
		cut_h = src.y + (top - src.y) * u
	else:
		cut_h = -1.0e9
	var a_d := a - (drift_delay if drift_delay >= 0.0 else ds)
	drift = drift_vel * a_d if a_d > 0.0 else Vector2.ZERO


## Центр облака над столбом в момент t (x, z): верх наклонённого столба + снос ветром.
func cloud_center(t: float) -> Vector2:
	var span := top - src.y
	var d := drift_at(t)
	return Vector2(src.x + lean.x * span + d.x, src.z + lean.y * span + d.y)


## Ось столба на высоте y (x, z) с учётом наклона и сноса (на момент последнего update_time).
func axis_at(y: float) -> Vector2:
	var dh := maxf(y - src.y, 0.0)
	return Vector2(src.x + lean.x * dh + drift.x, src.z + lean.y * dh + drift.y)


func to_dict() -> Dictionary:
	var ground := axis_at(src.y)
	return {
		"id": id,
		"static": is_static,
		"source": src,
		"ground_axis": Vector3(ground.x, src.y, ground.y),  # ось у земли с учётом сноса
		"top_m": top,
		"strength_ms": strength,
		"radius_m": radius,
		"envelope": env,
		"lean": lean,
		"has_cloud": has_cloud,
	}
