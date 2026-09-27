class_name VarioSynth
extends RefCounted
## Синтезатор звука вариометра (FR-23) — чистая математика, без нод, тестируется headless.
##
## Подъём: писк; частота, темп и скважность — из таблицы climb_tones (как у XC Tracer).
## Снижение ниже порога: гудение по таблице sink_tones (скважность 100 % — непрерывно).
## Между порогами — тишина.
## Без щелчков: фаза генератора непрерывна между вызовами, громкость меняется
## плавной S-образной огибающей (attack/release), частота скользит (frequency_glide_s).
## Период/скважность фиксируются в начале каждого писка — писк не рвётся посреди.
## Результат не зависит от того, какими кусками запрашивать отсчёты.

var mix_rate_hz: float = 22050.0
var amplitude: float = 0.6

var _climb_on: float = 0.1
var _sink_on: float = -2.5
var _hyst: float = 0.05
var _climb_tones: Array = []     # [[v, f, period_ms, duty_pct], ...] по возрастанию v
var _sink_tones: Array = []
var _attack_step: float = 1.0    # приращение огибающей за отсчёт
var _release_step: float = 1.0
var _freq_k: float = 1.0         # коэффициент сглаживания частоты за отсчёт
var _input_k: float = 1.0        # коэффициент сглаживания входа за отсчёт
var _chirp: float = 0.0          # относительный подъём частоты внутри писка
var _table: PackedFloat32Array = PackedFloat32Array()
var _table_size: int = 1024

# Состояние (переживает границы буферов).
var _target_vario: float = 0.0
var _vario: float = 0.0          # сглаженный вход
var _mode: int = 0               # 0 — тишина, 1 — подъём, −1 — снижение
var _phase: float = 0.0          # фаза генератора, доли периода 0..1
var _freq: float = 0.0           # текущая частота, Гц
var _cycle_pos: float = 0.0      # позиция в цикле писка, доли 0..1
var _cycle_period_s: float = 0.5 # период текущего цикла (зафиксирован в начале писка)
var _cycle_duty: float = 0.5
var _env: float = 0.0            # огибающая 0..1 (до S-формы)
var _counter: int = 0            # сквозной счётчик отсчётов (пересчёт тона раз в блок)
var _tone: Dictionary = {}       # текущий тон (см. tone_for)

const MODE_SILENT := 0
const MODE_CLIMB := 1
const MODE_SINK := -1


## cfg — раздел vario_audio из configs/audio.json.
func setup(cfg: Dictionary) -> void:
	mix_rate_hz = float(cfg.get("mix_rate_hz", mix_rate_hz))
	amplitude = float(cfg.get("amplitude", amplitude))
	_climb_on = float(cfg.get("climb_on_ms", _climb_on))
	_sink_on = float(cfg.get("sink_on_ms", _sink_on))
	_hyst = float(cfg.get("hysteresis_ms", _hyst))
	_climb_tones = _sorted_table(cfg.get("climb_tones", [[0.1, 400, 600, 50], [10.0, 1800, 150, 70]]))
	_sink_tones = _sorted_table(cfg.get("sink_tones", [[-10.0, 220, 1000, 100], [-2.5, 400, 1000, 100]]))
	_attack_step = 1.0 / maxf(float(cfg.get("attack_ms", 6.0)) * 0.001 * mix_rate_hz, 1.0)
	_release_step = 1.0 / maxf(float(cfg.get("release_ms", 8.0)) * 0.001 * mix_rate_hz, 1.0)
	_freq_k = _smoothing_k(float(cfg.get("frequency_glide_s", 0.03)))
	_input_k = _smoothing_k(float(cfg.get("input_smoothing_s", 0.05)))
	_chirp = float(cfg.get("climb_chirp_pct", 0.0)) * 0.01
	_table_size = maxi(int(cfg.get("wavetable_size", 1024)), 16)
	_build_table(cfg.get("harmonics", [1.0]))
	reset()


func reset() -> void:
	_mode = MODE_SILENT
	_phase = 0.0
	_env = 0.0
	_cycle_pos = 0.0
	_freq = 0.0
	_counter = 0
	_vario = _target_vario
	_tone = tone_for(_vario, _mode)


## Задать показание вариометра, м/с.
func set_vario(ms: float) -> void:
	_target_vario = ms


## Сразу принять значение без сглаживания входа (для тестов и включения прибора).
func jump_to(ms: float) -> void:
	_target_vario = ms
	_vario = ms


func get_mode() -> int:
	return _mode


## Тон для значения вариометра: {freq_hz, period_s, duty, mode}. Тишина — mode 0.
func tone_for(v: float, current_mode: int = MODE_SILENT) -> Dictionary:
	var mode := MODE_SILENT
	var climb_thr := _climb_on - (_hyst if current_mode == MODE_CLIMB else 0.0)
	var sink_thr := _sink_on + (_hyst if current_mode == MODE_SINK else 0.0)
	if v >= climb_thr:
		mode = MODE_CLIMB
	elif v <= sink_thr:
		mode = MODE_SINK
	if mode == MODE_SILENT:
		return {"mode": mode, "freq_hz": 0.0, "period_s": 1.0, "duty": 0.0}
	var row := _interp(_climb_tones if mode == MODE_CLIMB else _sink_tones, v)
	return {
		"mode": mode,
		"freq_hz": row[1],
		"period_s": maxf(row[2] * 0.001, 0.01),
		"duty": clampf(row[3] * 0.01, 0.0, 1.0),
	}


## Сгенерировать frames отсчётов (моно).
func generate(frames: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(frames)
	var inv_rate := 1.0 / mix_rate_hz
	var size_f := float(_table_size)
	# Тон пересчитываем раз в блок: вход меняется медленно (≥ десятков мс).
	var block := maxi(int(mix_rate_hz * 0.002), 1)
	var block_k := 1.0 - pow(1.0 - _input_k, block)
	var tone := _tone
	for i in frames:
		if _counter % block == 0:
			_vario += (_target_vario - _vario) * block_k
			tone = tone_for(_vario, _mode)
			_update_mode(tone)
			_tone = tone
		_counter += 1
		# Цикл писка.
		var gate := false
		if _mode == MODE_CLIMB:
			_cycle_pos += inv_rate / _cycle_period_s
			if _cycle_pos >= 1.0:
				_cycle_pos -= floorf(_cycle_pos)
				_cycle_period_s = tone.period_s
				_cycle_duty = tone.duty
			gate = _cycle_pos < _cycle_duty
		elif _mode == MODE_SINK:
			_cycle_pos += inv_rate / _cycle_period_s
			if _cycle_pos >= 1.0:
				_cycle_pos -= floorf(_cycle_pos)
				_cycle_period_s = tone.period_s
				_cycle_duty = tone.duty
			gate = _cycle_duty >= 1.0 or _cycle_pos < _cycle_duty
		# Огибающая: линейный ход + S-форма = плавные фронты.
		if gate:
			_env = minf(_env + _attack_step, 1.0)
		else:
			_env = maxf(_env - _release_step, 0.0)
		# Частота: скользит к целевой; когда звук погас — можно сразу к целевой.
		var target_f: float = tone.freq_hz
		if _mode == MODE_CLIMB and _chirp != 0.0:
			target_f *= 1.0 + _chirp * clampf(_cycle_pos / maxf(_cycle_duty, 1e-3), 0.0, 1.0)
		if target_f > 0.0:
			if _env <= 0.0 or _freq <= 0.0:
				_freq = target_f
			else:
				_freq += (target_f - _freq) * _freq_k
		_phase += _freq * inv_rate
		_phase -= floorf(_phase)
		if _env <= 0.0:
			out[i] = 0.0
			continue
		var pos := _phase * size_f
		var i0 := int(pos)
		var frac := pos - float(i0)
		var s := lerpf(_table[i0], _table[(i0 + 1) % _table_size], frac)
		var e := _env * _env * (3.0 - 2.0 * _env)
		out[i] = s * e * amplitude
	return out


## То же, стерео (для AudioStreamGeneratorPlayback.push_buffer).
func generate_stereo(frames: int) -> PackedVector2Array:
	var mono := generate(frames)
	var out := PackedVector2Array()
	out.resize(frames)
	for i in frames:
		out[i] = Vector2(mono[i], mono[i])
	return out


func _update_mode(tone: Dictionary) -> void:
	var new_mode: int = tone.mode
	if new_mode == _mode:
		return
	if new_mode != MODE_SILENT:
		# Новый режим — сразу начинаем писк/гудение с начала цикла.
		_cycle_pos = 0.0
		_cycle_period_s = tone.period_s
		_cycle_duty = tone.duty
	_mode = new_mode


func _smoothing_k(time_s: float) -> float:
	if time_s <= 0.0:
		return 1.0
	return 1.0 - exp(-1.0 / (time_s * mix_rate_hz))


func _build_table(harmonics: Array) -> void:
	_table.resize(_table_size)
	var peak := 0.0
	for i in _table_size:
		var x := TAU * float(i) / float(_table_size)
		var s := 0.0
		for h in harmonics.size():
			s += float(harmonics[h]) * sin(x * float(h + 1))
		_table[i] = s
		peak = maxf(peak, absf(s))
	if peak > 0.0:
		for i in _table_size:
			_table[i] /= peak


static func _sorted_table(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		out.append([float(r[0]), float(r[1]), float(r[2]), float(r[3])])
	out.sort_custom(func(a, b): return a[0] < b[0])
	return out


## Линейная интерполяция строки таблицы по вариометру; за краями — крайние строки.
static func _interp(rows: Array, v: float) -> Array:
	if rows.is_empty():
		return [v, 0.0, 1000.0, 0.0]
	if v <= rows[0][0]:
		return rows[0]
	if v >= rows[-1][0]:
		return rows[-1]
	for k in range(1, rows.size()):
		if v <= rows[k][0]:
			var a: Array = rows[k - 1]
			var b: Array = rows[k]
			var t: float = (v - a[0]) / maxf(b[0] - a[0], 1e-9)
			return [v, lerpf(a[1], b[1], t), lerpf(a[2], b[2], t), lerpf(a[3], b[3], t)]
	return rows[-1]
