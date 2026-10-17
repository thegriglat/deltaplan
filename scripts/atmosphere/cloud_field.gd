class_name CloudField
extends RefCounted
## Поле облачности региона (CLF-К1, docs/contracts/cloud-field.md; законы и границы —
## docs/research/cloud_field.md). Прогностическая модель на сетке региона поля воздуха (dx 400 м):
## столбец несёт активную облачную долю a (под работающим подъёмом), пассивную p (оторвавшиеся,
## тающие облака), мощность d и «накопленное переразвитие» od.
##
## Источник — подъём, дошедший до уровня конденсации (основание base_msl = LCL): доля площади
## восходящих потоков у основания a_u = Φ(LCL)/w_u (Φ(ζ) = 2Φ̄(1 − ζ) — профиль потока массы
## Холтслага–Бовилля, как в AirThermals; w_u — скорость ядра у основания), ядра источников
## AirThermals (carried) — отдельными кучевыми над точкой «источник + снос за время подъёма»,
## подъём склоном (w_mech у поверхности, вершины выше LCL — в облаке). Динамика:
##   da/dt = (a_u − a)/τ_form;  dp/dt = a/τ_life − p/τ_evap(d);  cover = a + p;
##   τ_evap(d) = τ_evap·clamp(d/d_ref, ½, 2) — мощные облака испаряются дольше тонких;
##   dd/dt = (D* − d)/τ_deepen при подъёме, −d/τ_evap без него; D* = min(k_moist·(c_top − LCL), D_cap);
##   d(od)/dt = (a_u/a_ref − od)/τ_od — башни переразвития у доли столбцов overdevelopment_chance.
## Снос — полулагранжев перенос состояния ветром на высоте основания (по столбцам), шаг переноса —
## когда средний снос набрал advect_cells клеток (меньше численной диффузии). Детерминизм: фиксированный
## шаг step_s, без часов и общего RNG; одинаковые входы и t → побитно те же массивы.
## Снимок/текстура — CloudFieldCodec (К2, К4), входы по столбцам — CloudFieldSources.

const FORMAT_VERSION := 1

## Сетка (как WindField: столбец c = j·nx + i, x = x0 + (i + ½)dx, z = −(y0 + (j + ½)dx)).
var nx: int = 0
var ny: int = 0
var dx: float = 400.0
var x0: float = 0.0
var y0: float = 0.0
## Основание (LCL), м над морем — общее на сетку.
var base_msl: float = 0.0
## Выходы по столбцам: покрытие 0..1, мощность над base_msl (м; 0 — нет облака), стадия −1..1
## (+1 растёт, 0 зрелое, −1 тает), активность 0..1 (доля облака под подъёмом сейчас).
var cover := PackedFloat32Array()
var depth := PackedFloat32Array()
var stage := PackedFloat32Array()
var activity := PackedFloat32Array()
## Фон вне сетки: среднее покрытие по сетке и средняя (по покрытию) мощность.
var bg_cover: float = 0.0
var bg_depth: float = 0.0
## Время поля, игровые с (последний сделанный шаг).
var time: float = 0.0
## Параметры (configs/atmosphere.json → cloud_field, К5).
var cfg: Dictionary = {}

## Состояние по столбцам.
var _a := PackedFloat32Array()
var _p := PackedFloat32Array()
var _d := PackedFloat32Array()
var _od := PackedFloat32Array()
## Столбцы-кандидаты на переразвитие (хеш seed+столбец < overdevelopment_chance).
var _tower := PackedByteArray()
## Чем помечены кандидаты: [seed, overdevelopment_chance]; пусто — ещё не помечены (ревью CLF-1).
var _tower_key := []
## Входы по столбцам (CloudFieldSources): прежние (au0, ds0) и новые (au1, ds1), снос у основания
## (vx, vz, м/с), рельеф столбцов (hc, м над морем).
var _au0 := PackedFloat32Array()
var _au1 := PackedFloat32Array()
var _ds0 := PackedFloat32Array()
var _ds1 := PackedFloat32Array()
var _vx := PackedFloat32Array()
var _vz := PackedFloat32Array()
var _hc := PackedFloat32Array()
var _has_inputs := false
## Смена входов: момент и длительность перехода (с), 0 — перехода нет.
var _blend_t0: float = 0.0
var _blend_s: float = 0.0
## Мощность облака дня (погода, м), доля переразвития, зерно.
var _depth_day: float = 800.0
var _overdev: float = 0.0
var _seed: int = 0
## Накопленный средний снос с последнего переноса (м) и время с него (с).
var _adv_disp: float = 0.0
var _adv_dt: float = 0.0
var _mean_v := Vector2.ZERO
var _inp: Dictionary = {}
var _started := false


func _init(config: Dictionary = {}) -> void:
	cfg = config
	if cfg.is_empty():
		cfg = Config.get_config("atmosphere").get("cloud_field", {})


func setup_grid(p_nx: int, p_ny: int, p_dx: float, p_x0: float, p_y0: float) -> void:
	nx = p_nx
	ny = p_ny
	dx = p_dx
	x0 = p_x0
	y0 = p_y0
	var n := nx * ny
	for arr: PackedFloat32Array in [
		cover, depth, stage, activity, _a, _p, _d, _od, _au0, _au1, _ds0, _ds1, _vx, _vz
	]:
		arr.resize(n)
		arr.fill(0.0)
	_hc.resize(n)
	_hc.fill(0.0)
	_tower.resize(n)
	_tower.fill(0)
	_tower_key = []
	_has_inputs = false
	_blend_s = 0.0
	_started = false


func signature() -> String:
	return "%.3f,%.3f,%.3f,%d,%d" % [dx, x0, y0, nx, ny]


## Входы (К1): air, wind_field, thermals, weather, cloudbase_msl, ground_ref, wind_at, seed.
## Применяются со следующего шага; переход от прежних входов — input_blend_s.
func set_inputs(inp: Dictionary) -> void:
	_inp = inp
	if nx == 0:
		var f: WindField = inp.get("wind_field")
		if f == null and inp.get("air") != null:
			f = (inp.air as AirThermals).level
		if f != null:
			setup_grid(f.nx, f.ny, f.dx, f.x0, f.y0)
	if nx == 0:
		return
	# основание: LCL погоды, иначе кромка
	var w: Dictionary = inp.get("weather", {}) if inp.get("weather") is Dictionary else {}
	var dv: Dictionary = w.get("_derived", {})
	if dv.has("z_lcl_msl_m"):
		base_msl = float(dv.z_lcl_msl_m)
	elif inp.get("cloudbase_msl") != null:
		base_msl = float(inp.cloudbase_msl)
	_depth_day = float(w.get("cloud_depth_m", cfg.get("depth_day_default_m", 800.0)))
	_overdev = clampf(float(w.get("overdevelopment_chance", 0.0)), 0.0, 1.0)
	var seed := int(inp.get("seed", 0))
	# кандидаты на башни — при первом входе и при смене зерна или доли переразвития (n хешей дёшево)
	if _tower_key != [seed, _overdev] or _tower.size() != nx * ny:
		_seed = seed
		_mark_towers()
		_tower_key = [seed, _overdev]
	var prep := CloudFieldSources.prepare(self, inp, cfg)
	# прежние входы — текущее смешанное значение; новые — со следующего шага
	var blend_s := float(cfg.get("input_blend_s", 60.0))
	if _has_inputs and blend_s > 0.0 and _started:
		var f := _blend_frac()
		for c in nx * ny:
			_au0[c] = _au0[c] + (_au1[c] - _au0[c]) * f
			_ds0[c] = _ds0[c] + (_ds1[c] - _ds0[c]) * f
		_blend_t0 = time
		_blend_s = blend_s
	else:
		_au0 = (prep.au as PackedFloat32Array).duplicate()
		_ds0 = (prep.ds as PackedFloat32Array).duplicate()
		_blend_s = 0.0
	_au1 = prep.au
	_ds1 = prep.ds
	_vx = prep.vx
	_vz = prep.vz
	_hc = prep.hc
	_mean_v = prep.mean_v
	_has_inputs = true


func _blend_frac() -> float:
	if _blend_s <= 0.0:
		return 1.0
	return clampf((time - _blend_t0) / _blend_s, 0.0, 1.0)


## Пустое поле + разгон до t от текущих входов (spinup_s).
func reset(t: float) -> void:
	for arr: PackedFloat32Array in [cover, depth, stage, activity, _a, _p, _d, _od]:
		arr.fill(0.0)
	bg_cover = 0.0
	bg_depth = 0.0
	_blend_s = 0.0
	_au0 = _au1.duplicate()
	_ds0 = _ds1.duplicate()
	_adv_disp = 0.0
	_adv_dt = 0.0
	var spin := float(cfg.get("spinup_s", 2400.0))
	time = t - spin
	_started = true
	_advance(t)
	time = t


## Шаги фиксированной длины step_s до t; назад или скачок больше spinup_s — reset(t).
func step_to(t: float) -> void:
	if nx == 0:
		return
	var spin := float(cfg.get("spinup_s", 2400.0))
	if not _started or t < time or t - time > spin:
		reset(t)
		return
	_advance(t)


func _advance(t: float) -> void:
	var dt := maxf(float(cfg.get("step_s", 20.0)), 0.1)
	while time + dt <= t + 1.0e-6:
		_step(dt)
		time += dt


## Отметить столбцы-кандидаты на башни переразвития (детерминированно по зерну).
func _mark_towers() -> void:
	var n := nx * ny
	_tower.resize(n)
	for c in n:
		var u := float(hash(Vector2i(c, _seed)) & 0xFFFF) / 65536.0
		_tower[c] = 1 if u < _overdev else 0


func _step(dt: float) -> void:
	var n := nx * ny
	if n == 0:
		return
	if not _has_inputs:
		return
	# --- снос: когда средний снос набрал advect_cells клеток
	_adv_dt += dt
	_adv_disp += _mean_v.length() * dt
	if _adv_disp >= float(cfg.get("advect_cells", 0.8)) * dx:
		_advect(_adv_dt)
		_adv_disp = 0.0
		_adv_dt = 0.0
	# --- локальная динамика
	var f := _blend_frac()
	var blending := _blend_s > 0.0 and f < 1.0
	var ka := minf(dt / maxf(float(cfg.get("tau_form_s", 240.0)), dt), 1.0)
	var kl := dt / maxf(float(cfg.get("tau_life_s", 900.0)), dt)
	# испарение пассивного облака — медленнее у мощных: τ_evap(d) = τ_evap·clamp(d/d_ref, ½, 2)
	var tau_evap := maxf(float(cfg.get("tau_evap_s", 1200.0)), dt)
	var inv_dref := 1.0 / maxf(float(cfg.get("evap_depth_ref_m", 1000.0)), 1.0)
	var kd := minf(dt / maxf(float(cfg.get("tau_deepen_s", 600.0)), dt), 1.0)
	var ko := minf(dt / maxf(float(cfg.get("tau_overdev_s", 1800.0)), dt), 1.0)
	var inv_aref := 1.0 / maxf(float(cfg.get("overdev_ref_frac", 0.1)), 1.0e-3)
	var tau_stage := float(cfg.get("tau_stage_s", 600.0)) / dt
	var q_floor := 0.02
	var cover_min := float(cfg.get("cover_min", 0.01))
	var depth_max := float(cfg.get("depth_max_m", 2500.0))
	var depth_day := _depth_day
	var a_arr := _a
	var p_arr := _p
	var d_arr := _d
	var od_arr := _od
	var au0 := _au0
	var au1 := _au1
	var ds0 := _ds0
	var ds1 := _ds1
	var tower := _tower
	var cov_arr := cover
	var dep_arr := depth
	var st_arr := stage
	var act_arr := activity
	var sum_c := 0.0
	var sum_cd := 0.0
	for c in n:
		var au := au1[c]
		var ds := ds1[c]
		if blending:
			au = au0[c] + (au - au0[c]) * f
			ds = ds0[c] + (ds - ds0[c]) * f
		var a := a_arr[c]
		var p := p_arr[c]
		var d := d_arr[c]
		var od := od_arr[c]
		var q0 := a + p
		var ke := minf(dt / (tau_evap * clampf(maxf(d, 100.0) * inv_dref, 0.5, 2.0)), 1.0)
		p += a * kl - p * ke
		a += (au - a) * ka
		od += (au * inv_aref - od) * ko
		var cap := depth_day
		if tower[c] == 1:
			cap += (depth_max - depth_day) * clampf(od, 0.0, 1.0)
		if au > 0.0:
			d += (minf(ds, cap) - d) * kd
		else:
			d -= d * ke
		var q := a + p
		var cov := minf(q, 1.0)
		if cov < cover_min:
			cov = 0.0
		cov_arr[c] = cov
		a_arr[c] = a
		p_arr[c] = p
		d_arr[c] = d
		od_arr[c] = od
		if cov > 0.0:
			dep_arr[c] = d
			st_arr[c] = clampf((q - q0) * tau_stage / maxf(q, q_floor), -1.0, 1.0)
			act_arr[c] = clampf(a / q, 0.0, 1.0)
			sum_c += cov
			sum_cd += cov * d
		else:
			dep_arr[c] = 0.0
			st_arr[c] = 0.0
			act_arr[c] = 0.0
	bg_cover = sum_c / n
	bg_depth = sum_cd / sum_c if sum_c > 0.0 else 0.0


## Полулагранжев перенос состояния за tau секунд ветром на высоте основания: значение столбца —
## билинейно из точки «центр − v·τ»; вне сетки — фон (a 0, p bg_cover, d bg_depth, od 0).
func _advect(tau: float) -> void:
	var a0 := _a.duplicate()
	var p0 := _p.duplicate()
	var d0 := _d.duplicate()
	var o0 := _od.duplicate()
	var a_arr := _a
	var p_arr := _p
	var d_arr := _d
	var od_arr := _od
	var vx := _vx
	var vz := _vz
	var k := tau / dx
	var bgc := bg_cover
	var bgd := bg_depth
	var w := nx
	var h := ny
	var wm1 := w - 1
	var hm1 := h - 1
	for j in h:
		for i in w:
			var c := j * w + i
			var ui := i - vx[c] * k
			var uj := j + vz[c] * k
			var i0 := floori(ui)
			var j0 := floori(uj)
			var fi := ui - i0
			var fj := uj - j0
			var w00 := (1.0 - fi) * (1.0 - fj)
			var w10 := fi * (1.0 - fj)
			var w01 := (1.0 - fi) * fj
			var w11 := fi * fj
			if i0 >= 0 and i0 < wm1 and j0 >= 0 and j0 < hm1:
				var s0 := j0 * w + i0
				var s1 := s0 + w
				a_arr[c] = w00 * a0[s0] + w10 * a0[s0 + 1] + w01 * a0[s1] + w11 * a0[s1 + 1]
				p_arr[c] = w00 * p0[s0] + w10 * p0[s0 + 1] + w01 * p0[s1] + w11 * p0[s1 + 1]
				d_arr[c] = w00 * d0[s0] + w10 * d0[s0 + 1] + w01 * d0[s1] + w11 * d0[s1 + 1]
				od_arr[c] = w00 * o0[s0] + w10 * o0[s0 + 1] + w01 * o0[s1] + w11 * o0[s1 + 1]
				continue
			# у края: клетки вне сетки — фон
			var sa := 0.0
			var sp := 0.0
			var sd := 0.0
			var so := 0.0
			for q in 4:
				var ii := i0 + (q & 1)
				var jj := j0 + (q >> 1)
				var wq := w00 if q == 0 else (w10 if q == 1 else (w01 if q == 2 else w11))
				if wq <= 0.0:
					continue
				if ii >= 0 and ii < w and jj >= 0 and jj < h:
					var s := jj * w + ii
					sa += wq * a0[s]
					sp += wq * p0[s]
					sd += wq * d0[s]
					so += wq * o0[s]
				else:
					sp += wq * bgc
					sd += wq * bgd
			a_arr[c] = sa
			p_arr[c] = sp
			d_arr[c] = sd
			od_arr[c] = so


# ------------------------------------------------------------------ выборка


## Билинейно по столбцам: индексы и веса для точки мира (x, z); пусто — сетки нет.
## Возвращает [c00, c10, c01, c11, fx, fy] (столбцы могут быть за краем → прижаты).
func _bilinear(x: float, z: float) -> Array:
	var u := (x - x0) / dx - 0.5
	var v := (-z - y0) / dx - 0.5
	var i0 := clampi(floori(u), 0, nx - 1)
	var j0 := clampi(floori(v), 0, ny - 1)
	var i1 := mini(i0 + 1, nx - 1)
	var j1 := mini(j0 + 1, ny - 1)
	var fx := clampf(u - i0, 0.0, 1.0)
	var fy := clampf(v - j0, 0.0, 1.0)
	return [j0 * nx + i0, j0 * nx + i1, j1 * nx + i0, j1 * nx + i1, fx, fy]


func _lerp4(arr: PackedFloat32Array, b: Array) -> float:
	var fx: float = b[4]
	var fy: float = b[5]
	var top := arr[b[0]] + (arr[b[1]] - arr[b[0]]) * fx
	var bot := arr[b[2]] + (arr[b[3]] - arr[b[2]]) * fx
	return top + (bot - top) * fy


## Вес сетки 0..1 в точке: 1 внутри, снаружи спад за edge_fade_m.
func _edge_weight(x: float, z: float) -> float:
	var fade := maxf(float(cfg.get("edge_fade_m", 2000.0)), 1.0)
	var ox := maxf(maxf(x0 - x, x - (x0 + nx * dx)), 0.0)
	var y := -z
	var oy := maxf(maxf(y0 - y, y - (y0 + ny * dx)), 0.0)
	var dist := sqrt(ox * ox + oy * oy)
	return clampf(1.0 - dist / fade, 0.0, 1.0)


## (cover, base_msl, base_msl + depth, stage) билинейно; вне сетки — фон с переходом edge_fade_m.
func sample(p: Vector3) -> Vector4:
	if nx == 0:
		return Vector4(bg_cover, base_msl, base_msl + bg_depth, 0.0)
	var b := _bilinear(p.x, p.z)
	var w := _edge_weight(p.x, p.z)
	var c := _lerp4(cover, b)
	var d := _lerp4(depth, b)
	var s := _lerp4(stage, b)
	c = bg_cover + (c - bg_cover) * w
	d = bg_depth + (d - bg_depth) * w
	s *= w
	return Vector4(c, base_msl, base_msl + d, s)


## Грубая плотность 0..1 без шума: покрытие × вертикальный профиль, 0 вне [base, base + depth].
func density_at(p: Vector3) -> float:
	var s := sample(p)
	var d := s.z - s.y
	if s.x <= 0.0 or d <= 0.0 or p.y < s.y or p.y > s.z:
		return 0.0
	var zeta := (p.y - s.y) / d
	return s.x * clampf(6.0 * zeta * (1.0 - zeta), 0.0, 1.0)


## Доля прямого солнца, закрытая полем над точкой земли xz: луч к солнцу до высоты основания,
## там покрытие × непрозрачность 1 − exp(−depth/shade_depth_m). Солнце у горизонта — 0.
func shade_at(xz: Vector2, sun_dir: Vector3) -> float:
	if nx == 0 or sun_dir.y <= 0.05:
		return 0.0
	var h := base_msl - 1000.0
	if _hc.size() == nx * ny and nx > 0:
		h = _lerp4(_hc, _bilinear(xz.x, xz.y))
	var dz := maxf(base_msl - h, 0.0)
	var off := dz / sun_dir.y
	var s := sample(Vector3(xz.x + sun_dir.x * off, base_msl, xz.y + sun_dir.z * off))
	var d := s.z - s.y
	if s.x <= 0.0 or d <= 0.0:
		return 0.0
	return s.x * (1.0 - exp(-d / maxf(float(cfg.get("shade_depth_m", 60.0)), 1.0)))


# ------------------------------------------------------------------ К2, К4


func to_image() -> Image:
	return CloudFieldCodec.to_image(self)


func snapshot() -> PackedByteArray:
	return CloudFieldCodec.snapshot(self)


func apply_snapshot(b: PackedByteArray, blend: float) -> bool:
	return CloudFieldCodec.apply_snapshot(self, b, blend)


## Состояние из выходов (после снимка): a = cover·activity, p = cover·(1 − activity), d = depth;
## накопленное переразвитие od — установившееся при таком подъёме, a/a_ref (od в снимке К4 не идёт;
## у ведущего и клиента башни тогда сходятся к одному за τ_od).
func _state_from_outputs() -> void:
	var inv_aref := 1.0 / maxf(float(cfg.get("overdev_ref_frac", 0.1)), 1.0e-3)
	for c in nx * ny:
		var q := cover[c]
		_a[c] = q * activity[c]
		_p[c] = q * (1.0 - activity[c])
		_d[c] = depth[c]
		_od[c] = clampf(_a[c] * inv_aref, 0.0, 1.0)
	_started = true
