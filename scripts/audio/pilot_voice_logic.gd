class_name PilotVoiceLogic
extends RefCounted
## Логика реплик пилота (PV-К1/PV-К4): по данным прибора и событиям решает, какую реплику начать.
## Без нод и звука; детерминирована при rng_seed. Все пороги — из configs/pilot_voice.json (params).
## Время — внутренние часы (сумма dt из update), секунды реального времени при скорости ×1.
## Модель: каждая ситуация даёт «срабатывание»; срабатывание уважает cooldown_s ситуации, бросает chance
## и (если выпало) встаёт в очередь; из очереди по одной выдаётся реплика с учётом gap_s, приоритета и max_wait_s.

const SITUATIONS: PackedStringArray = [
	"takeoff", "thermal_found", "thermal_strong", "thermal_lost", "sink", "turbulence", "stall", "fast",
	"low", "high", "view", "cloud", "turnpoint", "goal", "landing_soft", "landing_hard", "crash",
]
## Модель не стартует от нуля: до отрыва «никогда не говорили».
const NEVER := -1.0e9

var _cfg: Dictionary = {}
var _sit: Dictionary = {}
var _rules: Dictionary = {}
var _rng := RandomNumberGenerator.new()

var _clock := 0.0
var _flight_t := 0.0  ## с отрыва (или с reset)
var _last_fired: Dictionary = {}  ## id -> clock последнего срабатывания (cooldown_s)
var _history: Dictionary = {}  ## id -> последние сказанные номера вариантов
var _pending: Array = []  ## {id, ready, prio}
var _speaking := false
var _speaking_prio := 0
var _last_end := NEVER
var _last_started := ""
var _last_interrupt := false

# Состояние условий.
var _hold: Dictionary = {}  ## id -> непрерывное время условия
var _quiet_acc := 0.0
var _calm_t := 0.0
var _quiet_ok := false
var _win: Array = []  ## окно вариометра для thermal_lost: Vector2(dt, v)
var _win_t := 0.0
var _win_sum := 0.0
var _lost_armed := false
var _peaks: Array = []  ## времена выбросов перегрузки
var _over := false
var _low_armed := false
var _takeoff_msl := NAN
var _high_level := 0
var _landed_said := false
var _egg_done: Dictionary = {}  ## id -> true: пасхалка уже замечена в этом полёте
var _quiet_since := 0.0  ## с какого момента тишина (конец последней реплики / отрыв)


func setup(cfg: Dictionary, rng_seed: int = 0) -> void:
	_cfg = cfg
	_sit = cfg.get("situations", {})
	_rules = cfg.get("rules", {})
	_rng.seed = rng_seed
	reset()


## Новый полёт: паузы, «раз за полёт», ступени high, история вариантов.
func reset() -> void:
	_clock = 0.0
	_flight_t = 0.0
	_last_fired.clear()
	_history.clear()
	_pending.clear()
	_speaking = false
	_speaking_prio = 0
	_last_end = NEVER
	_last_started = ""
	_last_interrupt = false
	_takeoff_msl = NAN
	_high_level = 0
	_landed_said = false
	_egg_done.clear()
	_quiet_since = 0.0
	_reset_conditions()


func _reset_conditions() -> void:
	_hold.clear()
	_quiet_acc = 0.0
	_calm_t = 0.0
	_quiet_ok = false
	_win.clear()
	_win_t = 0.0
	_win_sum = 0.0
	_lost_armed = false
	_peaks.clear()
	_over = false
	_low_armed = false


func event(event_name: String, data := {}) -> void:
	match event_name:
		"took_off":
			_flight_t = 0.0
			_takeoff_msl = float(data.get("altitude_msl", NAN))
			_high_level = 0
			_landed_said = false
			_quiet_since = _clock
			_reset_conditions()
			_trigger("takeoff", p("takeoff", "delay_s", 0.0))
		"landed":
			if _landed_said:
				return
			var id := ""
			match String(data.get("grade", "")):
				"soft":
					id = "landing_soft"
				"hard":
					id = "landing_hard"
				"crash":
					id = "crash"
			if id != "":
				_landed_said = true
				_trigger(id, p(id, "delay_s", 0.0))
		"turnpoint":
			_trigger("turnpoint", 0.0)
		"goal":
			_trigger("goal", 0.0)
		"egg_seen":
			var egg_id := "egg_" + String(data.get("id", ""))
			if _sit.has(egg_id) and not _egg_done.has(egg_id) and _trigger(egg_id, 0.0):
				_egg_done[egg_id] = true


## Параметр ситуации из конфига.
func p(id: String, key: String, default: float = 0.0) -> float:
	var params: Dictionary = (_sit.get(id, {}) as Dictionary).get("params", {})
	return float(params.get(key, default))


## Вернуть line_id ("sink_2") — начать сейчас; "" — молчать.
func update(dt: float, s: Dictionary) -> String:
	_clock += dt
	if String(s.get("phase", "")) != "flying":
		_reset_conditions()
	else:
		_flight_t += dt
		_scan(dt, s)
	return _pick()


func line_finished() -> void:
	if _speaking:
		_speaking = false
		_last_end = _clock
		_quiet_since = _clock


func is_interrupting(line_id: String) -> bool:
	return _last_interrupt and line_id == _last_started


# --- Срабатывания -----------------------------------------------------------------------------------


func _gap(prio: int) -> float:
	return float((_rules.get("gap_s", {}) as Dictionary).get(str(prio), 0.0))


## Срабатывание ситуации (true — прошло проверки пауз; chance мог не выпасть): пауза ситуации, фоновые — не раньше quiet_after_takeoff_s, chance, очередь.
func _trigger(id: String, delay: float) -> bool:
	var cfg: Dictionary = _sit.get(id, {})
	if cfg.is_empty():
		return false
	var prio := int(cfg.get("priority", 1))
	if prio == 1 and _flight_t < float(_rules.get("quiet_after_takeoff_s", 0.0)):
		return false
	if _clock - float(_last_fired.get(id, NEVER)) < float(cfg.get("cooldown_s", 0.0)):
		return false
	_last_fired[id] = _clock
	if _rng.randf() < float(cfg.get("chance", 1.0)):
		_pending.append({"id": id, "ready": _clock + delay, "prio": prio})
	return true


## Непрерывное условие: накопленное время, пока cond; true, когда набралось hold_s (счётчик после срабатывания сброшен).
func _held(id: String, cond: bool, dt: float, hold_s: float) -> bool:
	if not cond:
		_hold[id] = 0.0
		return false
	var t: float = float(_hold.get(id, 0.0)) + dt
	if t >= hold_s:
		_hold[id] = 0.0
		return true
	_hold[id] = t
	return false


func _scan(dt: float, s: Dictionary) -> void:
	var v := float(s.get("vario_ms", 0.0))
	var airspeed := float(s.get("airspeed_ms", 0.0))
	var agl := float(s.get("altitude_agl", 0.0))
	var msl := float(s.get("altitude_msl", 0.0))
	var stalled := bool(s.get("stalled", false))

	# thermal_found: тихо quiet_s подряд, затем подъём.
	if v < p("thermal_found", "v_quiet_ms", 0.5):
		if _quiet_acc <= 0.0:
			_quiet_ok = false
		_quiet_acc += dt
		if _quiet_acc >= p("thermal_found", "quiet_s", 20.0):
			_quiet_ok = true
	else:
		_quiet_acc = 0.0
	var up := v >= p("thermal_found", "v_ms", 1.0)
	if _held("thermal_found", up and _quiet_ok, dt, p("thermal_found", "hold_s", 3.0)):
		_quiet_ok = false
		_trigger("thermal_found", 0.0)

	if _held("thermal_strong", v >= p("thermal_strong", "v_ms", 3.0), dt, p("thermal_strong", "hold_s", 4.0)):
		_trigger("thermal_strong", 0.0)

	# thermal_lost: за in_s среднее v >= v_in_ms (взводим), затем v <= v_out_ms hold_s.
	var in_s := p("thermal_lost", "in_s", 30.0)
	_win.append(Vector2(dt, v))
	_win_t += dt
	_win_sum += v * dt
	while _win.size() > 1 and _win_t - (_win[0] as Vector2).x >= in_s:
		var f: Vector2 = _win.pop_front()
		_win_t -= f.x
		_win_sum -= f.y * f.x
	if _win_t >= in_s - 1e-6 and _win_sum / _win_t >= p("thermal_lost", "v_in_ms", 0.8):
		_lost_armed = true
	if _held("thermal_lost", _lost_armed and v <= p("thermal_lost", "v_out_ms", -1.0), dt, p("thermal_lost", "hold_s", 5.0)):
		_lost_armed = false
		_trigger("thermal_lost", 0.0)

	var sink_ok := (
		v <= p("sink", "v_ms", -3.0) and not stalled and airspeed <= p("sink", "max_airspeed_ms", 15.0)
	)
	if _held("sink", sink_ok, dt, p("sink", "hold_s", 3.0)):
		_trigger("sink", 0.0)

	_scan_turbulence(dt, s, agl)

	var stall_ok := stalled and agl > p("stall", "min_agl_m", 5.0)
	if _held("stall", stall_ok, dt, p("stall", "hold_s", 0.5)):
		_trigger("stall", 0.0)

	if _held("fast", airspeed >= p("fast", "airspeed_ms", 22.0), dt, p("fast", "hold_s", 3.0)):
		_trigger("fast", 0.0)

	# low: взводится набором rearm_agl.
	if agl >= p("low", "rearm_agl", 200.0):
		_low_armed = true
	if _low_armed and agl < p("low", "agl_m", 80.0) and v < p("low", "v_ms", 0.0):
		_low_armed = false
		_trigger("low", 0.0)

	# view: спокойный полёт на высоте и тишина calm_s подряд.
	var calm_s := p("view", "calm_s", 60.0)
	var calm := agl >= p("view", "min_agl_m", 150.0) and absf(v) < p("view", "v_calm_ms", 1.0)
	_calm_t = _calm_t + dt if calm else 0.0
	if _calm_t >= calm_s and not _speaking and _clock - _quiet_since >= calm_s:
		_calm_t = 0.0
		_trigger("view", 0.0)

	# high: ступени высоты над точкой отрыва.
	if is_nan(_takeoff_msl):
		_takeoff_msl = msl
	var step := p("high", "step_m", 300.0)
	if step > 0.0:
		var level := int(floor((msl - _takeoff_msl) / step))
		if level > _high_level:
			_high_level = level
			_trigger("high", 0.0)

	if _held("cloud", float(s.get("cloud", 0.0)) >= p("cloud", "cloud", 0.6), dt, p("cloud", "hold_s", 1.0)):
		_trigger("cloud", 0.0)


func _scan_turbulence(dt: float, s: Dictionary, agl: float) -> void:
	if agl <= p("turbulence", "min_agl_m", 10.0):
		_over = false
		_peaks.clear()
		return
	var cb := maxf(cos(deg_to_rad(float(s.get("bank_deg", 0.0)))), 0.2)
	var dev := absf(float(s.get("load_factor", 1.0)) - 1.0 / cb)
	var over := dev >= p("turbulence", "n_dev", 0.4)
	if over and not _over:
		_peaks.append(_clock)
	_over = over
	var window := p("turbulence", "window_s", 8.0)
	while not _peaks.is_empty() and _clock - float(_peaks[0]) > window:
		_peaks.pop_front()
	if _peaks.size() >= int(p("turbulence", "peaks", 3.0)):
		_peaks.clear()
		_trigger("turbulence", 0.0)


# --- Выдача ------------------------------------------------------------------------------------------


func _pick() -> String:
	var max_wait := float(_rules.get("max_wait_s", 3.0))
	var keep: Array = []
	for e: Dictionary in _pending:
		if _clock - float(e.ready) <= max_wait:
			keep.append(e)
	_pending = keep
	var best := -1
	for i in _pending.size():
		var e: Dictionary = _pending[i]
		if float(e.ready) > _clock:
			continue
		if best < 0 or int(e.prio) > int(_pending[best].prio):
			best = i  # при равенстве приоритета остаётся более ранняя
	if best < 0:
		return ""
	var e: Dictionary = _pending[best]
	var prio := int(e.prio)
	var interrupt := false
	if _speaking:
		if not (_speaking_prio == 1 and prio == 3):
			return ""
		interrupt = true
	elif _clock - _last_end < _gap(prio):
		return ""
	_pending.remove_at(best)
	var id: String = e.id
	_speaking = true
	_speaking_prio = prio
	_last_interrupt = interrupt
	_last_started = "%s_%d" % [id, _choose(id) + 1]
	return _last_started


## Номер варианта (с нуля): не совпадает с последним сказанным (при 3 и более вариантах — с двумя последними).
func _choose(id: String) -> int:
	var n := ((_sit.get(id, {}) as Dictionary).get("lines", []) as Array).size()
	if n <= 1:
		return 0
	var hist: Array = _history.get(id, [])
	var avoid := mini(n - 1, 2)
	var recent: Array = hist.slice(maxi(0, hist.size() - avoid))
	var options: Array = []
	for i in n:
		if not recent.has(i):
			options.append(i)
	var k: int = options[_rng.randi() % options.size()]
	hist.append(k)
	_history[id] = hist
	return k
