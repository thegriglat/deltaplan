class_name RemotePilotState
extends RefCounted
## Состояние одного чужого пилота или бота по сети: буфер снимков PilotState по времени
## зоны t, интерполяция с задержкой, экстраполяция при потерях, «пропал» (NET-32).
## Чистая логика без сети и узлов — тестируется напрямую (tests/net/test_interpolation.gd).
##
## Использование (NetPilots делает это сам):
##   var r := RemotePilotState.new("7")
##   r.push(data, recv_s)                 # data — PilotState (словарь NetMessages)
##   var s := r.sample(zone_time - RemotePilotState.INTERP_DELAY_S)
##   r.is_lost(recv_now_s)                # 5 с без пакетов
##
## sample(render_t) → словарь:
##   pos: Vector3, rot: Quaternion, vel: Vector3 — мир Godot (м, м/с);
##   phase: String — фаза без префикса: "STAND" "WALK" "RUN" "FLY" "LANDED" "CRASHED" "TOW"
##       ("UNSPECIFIED", пока не пришла ни одна фаза);
##   id, name, wing ("wings/sport"), colors (WingColors-словарь {hueDeg, sat, value} или
##       null — родная текстура), is_bot — последние известные;
##   t: float — время зоны отрисованного состояния (= render_t, кроме удержания);
##   mode: String — "interp" | "extrap" (буфер кончился, ≤ 1 с по скорости) | "hold"
##       (дольше 1 с — стоит на месте, vel = 0) | "empty" (снимков ещё нет).
##
## Интерполяция — кубический Эрмит по позициям и скоростям соседних снимков (траектория
## гладкая и на вираже), ориентация — slerp, скорость — линейно. Снимки со временем раньше
## уже отрисованного или повторы отбрасываются (пришли не по порядку — поздно).
##
## Неполные пакеты (см. docs/net_protocol.md, PilotState): name/wing/colors приходят раз в
## секунду и при изменении — пакет «полный», если в нём есть wing; phase — при изменении и
## раз в секунду, нет (UNSPECIFIED) → прежняя.

## Задержка отрисовки за часами зоны, с: 10 Гц + джиттер ±50 мс.
const INTERP_DELAY_S := 0.15
## Экстраполяция по скорости, когда буфер кончился, не дольше, с; дальше — стоит.
const MAX_EXTRAP_S := 1.0
## Нет пакетов дольше — пилот пропал, с.
const LOST_AFTER_S := 5.0
## Предел буфера снимков.
const MAX_SNAPSHOTS := 32
const PHASE_PREFIX := "PILOT_PHASE_"
const PHASE_NONE := "UNSPECIFIED"

var id := ""
var is_bot := false
var name := ""
var wing := ""
var colors: Variant = null
## Время зоны последнего снимка; время получения последнего пакета (часы получателя).
var latest_t := -INF
var last_recv_s := -INF

## Снимки по возрастанию t: {t, pos, rot, vel, phase}.
var _snaps: Array[Dictionary] = []
## Самое позднее время, на которое уже отрисовали: раньше него снимки не принимаем.
var _rendered_t := -INF
var _phase := PHASE_NONE


func _init(p_id: String = "") -> void:
	id = p_id


## Пакет PilotState (данные NetMessages.decode) получен в recv_s (монотонные с получателя).
## false — отброшен (повтор или опоздал: раньше уже отрисованного).
func push(data: Dictionary, recv_s: float) -> bool:
	last_recv_s = maxf(last_recv_s, recv_s)
	if data.get("isBot", false):
		is_bot = true
	var t: float = float(data.get("t", 0.0))
	if str(data.get("wing", "")) != "":
		# полный пакет: метаданные как есть (colors нет → родная текстура)
		name = str(data.get("name", ""))
		wing = str(data.wing)
		colors = data.get("colors")
	var phase := short_phase(str(data.get("phase", "")))
	if t <= _rendered_t:
		return false
	var at := _snaps.size()
	while at > 0 and _snaps[at - 1].t >= t:
		at -= 1
	if at < _snaps.size() and is_equal_approx(_snaps[at].t, t):
		return false
	# фазы нет в пакете → как у предыдущего снимка
	if phase == PHASE_NONE:
		phase = _snaps[at - 1].phase if at > 0 else _phase
	var snap := {
		"t": t,
		"pos": NetMessages.to_vector3(data.get("pos")),
		"rot": NetMessages.to_quaternion(data.get("rot")),
		"vel": NetMessages.to_vector3(data.get("vel")),
		"phase": phase,
	}
	_snaps.insert(at, snap)
	if t >= latest_t:
		latest_t = t
		_phase = phase
	while _snaps.size() > MAX_SNAPSHOTS:
		_snaps.pop_front()
	return true


## Состояние на время зоны render_t (обычно zone_time() − INTERP_DELAY_S).
func sample(render_t: float) -> Dictionary:
	var out := {
		"id": id,
		"is_bot": is_bot,
		"name": name,
		"wing": wing,
		"colors": colors,
		"phase": _phase,
		"t": render_t,
		"pos": Vector3.ZERO,
		"rot": Quaternion.IDENTITY,
		"vel": Vector3.ZERO,
		"mode": "empty",
	}
	if _snaps.is_empty():
		return out
	_rendered_t = maxf(_rendered_t, render_t)
	var first: Dictionary = _snaps[0]
	var last: Dictionary = _snaps[_snaps.size() - 1]
	if render_t <= first.t:
		_fill(out, first, "interp")
		out.t = first.t
		return out
	if render_t >= last.t:
		var ex: float = render_t - float(last.t)
		if ex <= MAX_EXTRAP_S:
			_fill(out, last, "extrap")
			out.pos = last.pos + last.vel * ex
		else:
			_fill(out, last, "hold")
			out.pos = last.pos + last.vel * MAX_EXTRAP_S
			out.vel = Vector3.ZERO
			out.t = last.t + MAX_EXTRAP_S
		_trim(_snaps.size() - 1)
		return out
	var i := 0
	while _snaps[i + 1].t < render_t:
		i += 1
	var a: Dictionary = _snaps[i]
	var b: Dictionary = _snaps[i + 1]
	var dt: float = b.t - a.t
	var s: float = (render_t - a.t) / dt
	_fill(out, a, "interp")
	out.pos = hermite(a.pos, a.vel, b.pos, b.vel, dt, s)
	out.rot = (a.rot as Quaternion).slerp(b.rot, s)
	out.vel = (a.vel as Vector3).lerp(b.vel, s)
	_trim(i)
	return out


## Нет пакетов дольше LOST_AFTER_S к моменту now_s (те же часы, что recv_s в push).
func is_lost(now_s: float) -> bool:
	return now_s - last_recv_s > LOST_AFTER_S


func snapshot_count() -> int:
	return _snaps.size()


## Кубический Эрмит: p0, v0 → p1, v1 за dt, доля s ∈ [0, 1].
static func hermite(
	p0: Vector3, v0: Vector3, p1: Vector3, v1: Vector3, dt: float, s: float
) -> Vector3:
	var s2 := s * s
	var s3 := s2 * s
	var h00 := 2.0 * s3 - 3.0 * s2 + 1.0
	var h10 := s3 - 2.0 * s2 + s
	var h01 := -2.0 * s3 + 3.0 * s2
	var h11 := s3 - s2
	return p0 * h00 + v0 * (h10 * dt) + p1 * h01 + v1 * (h11 * dt)


## "PILOT_PHASE_FLY" / "FLY" → "FLY"; пусто или незнакомое → "UNSPECIFIED".
static func short_phase(phase: String) -> String:
	var p := phase.trim_prefix(PHASE_PREFIX)
	var names: Array = NetMessages.ENUMS["PilotPhase"]
	return p if p != "" and names.has(PHASE_PREFIX + p) else PHASE_NONE


func _fill(out: Dictionary, snap: Dictionary, mode: String) -> void:
	out.pos = snap.pos
	out.rot = snap.rot
	out.vel = snap.vel
	out.phase = snap.phase
	out.mode = mode


## Выбросить снимки до keep_from (они уже в прошлом отрисовки).
func _trim(keep_from: int) -> void:
	for k in keep_from:
		_snaps.pop_front()
