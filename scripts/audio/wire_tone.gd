class_name WireTone
extends RefCounted
## Эоловый тон тросов (SPF-К3): процедурный синтез без нод, тестируется headless.
## Срыв вихрей с натянутого троса диаметром d даёт тон f = St · V / d (число Струхаля St ≈ 0,2).
## Каждый трос — синусоида с фазой, накапливаемой по ∫2πf dt (скорость меняется без щелчков),
## медленной случайной огибающей громкости и дрейфом частоты (срыв вихрей нерегулярен)
## плюс слабая 2-я гармоника. Громкость микса — не здесь (volume_db плеера, FlightSoundMix).
## Параметры — configs/audio.json → flight.airflow.wire_tone.

## Длина блока, кадров: частоты и огибающие считаются раз в блок, амплитуда плавно — по кадрам.
const BLOCK := 32
const TAU_F := TAU

var mix_rate: float = 22050.0

var _st: float = 0.2
var _d: PackedFloat32Array = PackedFloat32Array()
var _gain: PackedFloat32Array = PackedFloat32Array()
var _pan: PackedFloat32Array = PackedFloat32Array()
var _h2: float = 0.15
var _wander: float = 0.012
var _wander_hz: float = 0.8
var _env_hz: float = 0.7
var _env_depth: float = 0.6
var _speed_smooth_s: float = 0.12
var _gate_ramp_s: float = 0.08
var _min_v: float = 3.0
var _master: float = 0.8
var _fmax_frac: float = 0.45

var _rng := RandomNumberGenerator.new()
var _v_target: float = 0.0
var _v: float = 0.0
var _gate: float = 0.0
var _phase: PackedFloat64Array = PackedFloat64Array()
var _amp_prev: PackedFloat32Array = PackedFloat32Array()
# Случайные узлы (значение 0..1 / -1..1) и положение между ними, отдельно для огибающей и дрейфа.
var _env_k0: PackedFloat32Array = PackedFloat32Array()
var _env_k1: PackedFloat32Array = PackedFloat32Array()
var _env_u: PackedFloat32Array = PackedFloat32Array()
var _env_du: PackedFloat32Array = PackedFloat32Array()
var _fm_k0: PackedFloat32Array = PackedFloat32Array()
var _fm_k1: PackedFloat32Array = PackedFloat32Array()
var _fm_u: PackedFloat32Array = PackedFloat32Array()
var _fm_du: PackedFloat32Array = PackedFloat32Array()
var _norm: float = 1.0


## cfg — flight.airflow.wire_tone; mix_rate — частота дискретизации генератора, Гц.
func setup(cfg: Dictionary, mix_rate_hz: float, seed_value: int = 0) -> void:
	mix_rate = maxf(mix_rate_hz, 1000.0)
	_st = float(cfg.get("strouhal", 0.2))
	_d = PackedFloat32Array(cfg.get("diameters_m", [0.0024, 0.003, 0.0038, 0.0048]))
	var n := _d.size()
	_gain = _fit(cfg.get("gains", []), n, 1.0)
	_pan = _fit(cfg.get("pan", []), n, 0.0)
	_h2 = float(cfg.get("harmonic_gain", 0.15))
	_wander = float(cfg.get("wander_frac", 0.012))
	_wander_hz = maxf(float(cfg.get("wander_hz", 0.8)), 0.01)
	_env_hz = maxf(float(cfg.get("env_hz", 0.7)), 0.01)
	_env_depth = clampf(float(cfg.get("env_depth", 0.6)), 0.0, 1.0)
	_speed_smooth_s = maxf(float(cfg.get("speed_smooth_s", 0.12)), 1e-3)
	_gate_ramp_s = maxf(float(cfg.get("gate_ramp_s", 0.08)), 1e-3)
	_min_v = float(cfg.get("min_airspeed_ms", 3.0))
	_master = clampf(float(cfg.get("level", 0.8)), 0.0, 1.0)
	_fmax_frac = float(cfg.get("max_freq_frac", 0.45))
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	# Нормировка: пик суммы ≤ _master при любых огибающих и панораме.
	var sum := 0.0
	for g in _gain:
		sum += g * (1.0 + _h2)
	_norm = _master / maxf(sum, 1e-6)
	_phase.resize(n)
	_amp_prev.resize(n)
	for k in [_env_k0, _env_k1, _env_u, _env_du, _fm_k0, _fm_k1, _fm_u, _fm_du]:
		k.resize(n)
	for i in n:
		_phase[i] = _rng.randf() * TAU_F
		_amp_prev[i] = 0.0
		_env_k0[i] = _rng.randf()
		_env_k1[i] = _rng.randf()
		_env_u[i] = _rng.randf()
		_env_du[i] = 0.0
		_fm_k0[i] = _rng.randf_range(-1.0, 1.0)
		_fm_k1[i] = _rng.randf_range(-1.0, 1.0)
		_fm_u[i] = _rng.randf()
		_fm_du[i] = 0.0
	_v = _v_target
	_gate = 0.0


## Воздушная скорость, м/с (частоты следуют к ней плавно).
func set_airspeed(v_ms: float) -> void:
	_v_target = maxf(v_ms, 0.0)


## Текущие частоты тросов f_i = St · V / d_i, Гц (по сглаженной скорости, как в звуке).
func frequencies() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_d.size())
	for i in _d.size():
		out[i] = _st * _v / _d[i]
	return out


## Стерео-кадры, |сэмпл| ≤ 1. Тишина (нули) при скорости ниже порога.
func fill(frames: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(maxi(frames, 0))
	var n := _d.size()
	var pos := 0
	var block_dt := float(BLOCK) / mix_rate
	var k_v := 1.0 - exp(-block_dt / _speed_smooth_s)
	var k_g := 1.0 - exp(-block_dt / _gate_ramp_s)
	var fmax := _fmax_frac * mix_rate
	var amp := PackedFloat32Array()
	amp.resize(n)
	var dth := PackedFloat64Array()
	dth.resize(n)
	var h2 := PackedFloat32Array()
	h2.resize(n)
	while pos < frames:
		var len := mini(BLOCK, frames - pos)
		_v = lerpf(_v, _v_target, k_v)
		var gate_t := 1.0 if _v_target >= _min_v else 0.0
		_gate = lerpf(_gate, gate_t, k_g)
		if gate_t == 0.0 and _gate < 1e-4:
			_gate = 0.0
		if _gate == 0.0:
			# Тишина: нули, фазы и огибающие замирают (выход из тишины без скачка).
			for i in n:
				_amp_prev[i] = 0.0
			pos += len
			continue
		for i in n:
			var f := _st * _v / _d[i]
			var fm := _step_knots(_fm_k0, _fm_k1, _fm_u, _fm_du, i, _wander_hz, block_dt, true)
			f *= 1.0 + _wander * fm
			var audible := f <= fmax and f > 1.0
			dth[i] = TAU_F * f / mix_rate
			h2[i] = _h2 if (audible and 2.0 * f <= fmax) else 0.0
			var e := _step_knots(_env_k0, _env_k1, _env_u, _env_du, i, _env_hz, block_dt, false)
			amp[i] = (
				(1.0 - _env_depth + _env_depth * e) * _gain[i] * _norm * _gate if audible else 0.0
			)
		for j in len:
			var l := 0.0
			var r := 0.0
			var t := float(j + 1) / float(len)
			for i in n:
				var a := lerpf(_amp_prev[i], amp[i], t)
				if a == 0.0:
					_phase[i] = fposmod(_phase[i] + dth[i], TAU_F)
					continue
				var th: float = _phase[i] + dth[i]
				_phase[i] = th
				var s := a * (sin(th) + h2[i] * sin(2.0 * th))
				var p := _pan[i]
				l += s * (1.0 - maxf(p, 0.0))
				r += s * (1.0 + minf(p, 0.0))
			out[pos + j] = Vector2(clampf(l, -1.0, 1.0), clampf(r, -1.0, 1.0))
		for i in n:
			_phase[i] = fposmod(_phase[i], TAU_F)
			_amp_prev[i] = amp[i]
		pos += len
	return out


## Следующее значение случайного сигнала с косинусной интерполяцией между узлами.
## centered — узлы −1..1, иначе 0..1. Интервал между узлами случаен около 1/rate_hz.
func _step_knots(
	k0: PackedFloat32Array,
	k1: PackedFloat32Array,
	u: PackedFloat32Array,
	du: PackedFloat32Array,
	i: int,
	rate_hz: float,
	dt: float,
	centered: bool
) -> float:
	if du[i] == 0.0:
		du[i] = rate_hz * _rng.randf_range(0.6, 1.6)
	u[i] += du[i] * dt
	while u[i] >= 1.0:
		u[i] -= 1.0
		k0[i] = k1[i]
		k1[i] = _rng.randf_range(-1.0, 1.0) if centered else _rng.randf()
		du[i] = rate_hz * _rng.randf_range(0.6, 1.6)
	var w := 0.5 - 0.5 * cos(PI * u[i])
	return lerpf(k0[i], k1[i], w)


static func _fit(src: Array, n: int, fallback: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = float(src[i]) if i < src.size() else fallback
	return out
