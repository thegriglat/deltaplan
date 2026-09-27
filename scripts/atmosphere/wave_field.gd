class_name WaveField
extends RefCounted
## Подветренные волны (VR-27): упрощённая линейная теория захваченных волн за хребтом.
##
## При устойчивой стратификации (частота Брента — Вяйсяля N) поток, перевалив хребет, колеблется
## с длиной волны λ = 2πU/N. Смещение линий тока в точке — свёртка уклона рельефа против ветра
## с откликом g(d) = cos(k·d)·exp(−d/L):
##   η(p)  = Σ h'(p − ŵd)·g(d)·Δ           (м; > 0 — гребень волны, там лентикулярные облака)
##   w(p)  = U·∂η/∂x = U·Σ h'(p − ŵd)·g'(d)·Δ
## По высоте волна нарастает от уровня гребня хребта до пика и медленно гаснет выше.
## Под гребнями волн у земли — роторы (сильная болтанка).
## Поля считаются на грубой сетке кусками (дорого: ~25 высот на узел) — только в волновой погоде.

const _KEY_OFFSET := 1 << 20
const _KEY_MUL := 1 << 21
const _FIELDS := 3  ## η, ∂η/∂x (на 1 м/с ветра), высота гребня против ветра

var enabled: bool = false
var ground: GroundField

var _cell: float = 300.0
var _n: int = 8
var _stride: int = 9
var _max_chunks: int = 200
var _strength: float = 0.0
var _n_bv: float = 0.01
var _k: float = 0.001
var _lambda: float = 6000.0
var _decay_waves: float = 3.0
var _gain: float = 0.3
var _max_w: float = 8.0
var _peak_m: float = 2000.0
var _depth_m: float = 5000.0
var _below_crest_m: float = 300.0
var _rotor_k: float = 0.3
var _rotor_depth_m: float = 400.0
var _rotor_ref_m: float = 300.0
var _samples: int = 24
var _wind_dir: Vector2 = Vector2(0, 1)
var _chunks: Dictionary = {}


func setup(wave_cfg: Dictionary, weather: Dictionary, g: GroundField) -> void:
	ground = g
	_strength = float(weather.get("wave_strength", 0.0))
	enabled = _strength > 0.0
	_n_bv = float(weather.get("stability_n_per_s", wave_cfg.default_stability_n_per_s))
	_cell = float(wave_cfg.cell_m)
	_n = int(wave_cfg.chunk_cells)
	_stride = _n + 1
	_max_chunks = int(wave_cfg.max_chunks)
	_decay_waves = float(wave_cfg.decay_wavelengths)
	_gain = float(wave_cfg.gain)
	_max_w = float(wave_cfg.max_ms)
	_peak_m = float(wave_cfg.peak_above_crest_m)
	_depth_m = float(wave_cfg.decay_height_m)
	_below_crest_m = float(wave_cfg.below_crest_m)
	_rotor_k = float(wave_cfg.rotor_turbulence_per_wind)
	_rotor_depth_m = float(wave_cfg.rotor_depth_m)
	_rotor_ref_m = float(wave_cfg.rotor_ref_m)
	_samples = int(wave_cfg.upwind_samples)


## Ветер над хребтами (м/с) и направление, куда дует: задаёт длину волны.
func set_wind(speed_ms: float, dir: Vector2) -> void:
	var lam := TAU * maxf(speed_ms, 1.0) / maxf(_n_bv, 1.0e-4)
	if dir.length_squared() > 1.0e-6:
		dir = dir.normalized()
	if absf(lam - _lambda) > 1.0 or dir.distance_to(_wind_dir) > 1.0e-3:
		_chunks.clear()
	_lambda = lam
	_k = TAU / lam
	_wind_dir = dir


func wavelength() -> float:
	return _lambda


## (η, ∂η/∂x, гребень) в точке — билинейно по сетке.
func fields(x: float, z: float) -> Vector3:
	var fx := x / _cell
	var fz := z / _cell
	var ix := floori(fx)
	var iz := floori(fz)
	var cx := floori(float(ix) / _n)
	var cz := floori(float(iz) / _n)
	var key := (cx + _KEY_OFFSET) * _KEY_MUL + (cz + _KEY_OFFSET)
	var d: PackedFloat32Array = _chunks.get(key, PackedFloat32Array())
	if d.is_empty():
		d = _build(cx, cz)
		if _chunks.size() >= _max_chunks:
			_chunks.clear()
		_chunks[key] = d
	var lx := ix - cx * _n
	var lz := iz - cz * _n
	var tx := fx - ix
	var tz := fz - iz
	var out := Vector3.ZERO
	for f in _FIELDS:
		var i00 := (lz * _stride + lx) * _FIELDS + f
		var i10 := i00 + _FIELDS
		var i01 := i00 + _stride * _FIELDS
		var i11 := i01 + _FIELDS
		out[f] = lerpf(lerpf(d[i00], d[i10], tx), lerpf(d[i01], d[i11], tx), tz)
	return out


## Вертикальный поток и σ роторной болтанки: Vector2(w, σ).
## u — ветер на уровне гребня (м/с), y — высота точки, agl — над землёй.
func sample(pos: Vector3, agl: float, u: float) -> Vector2:
	if not enabled or not ground.has_ground:
		return Vector2.ZERO
	var f := fields(pos.x, pos.z)
	var crest := f.z
	var z := pos.y
	# По высоте: от уровня гребня до пика, выше медленно гаснет.
	var prof := smoothstep(crest - _below_crest_m, crest + _peak_m * 0.4, z)
	prof *= exp(-maxf(0.0, z - crest - _peak_m) / _depth_m)
	var w := clampf(_strength * _gain * u * f.y * prof, -_max_w, _max_w)
	# Ротор: у земли, ниже гребня хребта + rotor_depth, под гребнем волны (η > 0).
	var rotor := 0.0
	if z < crest + _rotor_depth_m and f.x > 0.0:
		rotor = _strength * _rotor_k * u * clampf(f.x / _rotor_ref_m, 0.0, 1.0)
		rotor *= 1.0 - smoothstep(crest, crest + _rotor_depth_m, z)
		rotor *= smoothstep(0.0, 60.0, agl)
	return Vector2(w, rotor)


## Гребни волн рядом с точкой (для лентикулярных облаков): локальные максимумы η на сетке.
## Возвращает [{pos: Vector2, eta: float, crest: float}], сильные первыми.
func crests(center: Vector3, radius: float, min_eta: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not enabled or not ground.has_ground:
		return out
	var step := _cell * 2.0
	var n := int(radius / step)
	var grid: Dictionary = {}
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var p := Vector2(center.x + i * step, center.z + j * step)
			grid[Vector2i(i, j)] = fields(p.x, p.y)
	for j in range(-n + 1, n):
		for i in range(-n + 1, n):
			var f: Vector3 = grid[Vector2i(i, j)]
			if f.x < min_eta:
				continue
			var is_max := true
			for dj in range(-1, 2):
				for di in range(-1, 2):
					if (di != 0 or dj != 0) and (grid[Vector2i(i + di, j + dj)] as Vector3).x > f.x:
						is_max = false
			if is_max:
				out.append({
					"pos": Vector2(center.x + i * step, center.z + j * step),
					"eta": f.x, "crest": f.z,
				})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.eta > b.eta)
	return out


func _build(cx: int, cz: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_stride * _stride * _FIELDS)
	var dd := _lambda / 8.0
	var decay_l := _lambda * _decay_waves
	for j in _stride:
		for i in _stride:
			var x := (cx * _n + i) * _cell
			var z := (cz * _n + j) * _cell
			var eta := 0.0
			var deta := 0.0
			var crest := ground.height(x, z)
			var h_prev := crest
			for s in _samples:
				var d := (s + 1) * dd
				var h := ground.height(x - _wind_dir.x * d, z - _wind_dir.y * d)
				crest = maxf(crest, h) if d < _lambda * 2.0 else crest
				# Уклон по ветру на отрезке [d, d − dd]: подъём рельефа к точке — положительный.
				var slope := (h_prev - h) / dd
				h_prev = h
				var dm := d - dd * 0.5
				var e := exp(-dm / decay_l)
				eta += slope * cos(_k * dm) * e * dd
				deta += slope * (-_k * sin(_k * dm) - cos(_k * dm) / decay_l) * e * dd
			var o := (j * _stride + i) * _FIELDS
			out[o] = eta
			out[o + 1] = deta
			out[o + 2] = crest
	return out
