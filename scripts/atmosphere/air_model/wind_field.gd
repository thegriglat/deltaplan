class_name WindField
extends RefCounted
## Среднее поле воздуха (масштаб 1) одного уровня на CPU: декартова сетка MAC с маской «клетка под
## землёй» (решение AM-01, tools/research/air3d/reference.md), значения — в центрах клеток.
## Описание — docs/air_model.md → «Поле на CPU».
##
## Раскладка (как у решателя, без ореола): массив (nz, ny, nx), индекс (k·ny + j)·nx + i;
## i — восток (x мира), j — север (y = −Z мира), k — вверх (высота над морем). Центр клетки:
## x = x0 + (i + ½)·dx, y = y0 + (j + ½)·dx, z = z_bot + (k + ½)·dz. Клетка под землёй, если z её
## центра < hc столбца (hc — высота рельефа сетки, блочное среднее).
## Каналы: u, v (восток, север), w_mech (механическая вертикаль — решение без нагрева), w_conv
## (конвективная = w − w_mech), theta (θ′, К).
##
## Выборка (sample): по 4 соседним столбцам — по вертикали линейно между центрами клеток; ниже
## центра первой воздушной клетки столбца — логарифмический профиль к нулю на z0 (как трение в
## решателе); затем билинейно по столбцам. Высота у земли — по реальной высоте над рельефом:
## столбец c читается на высоте z_c = y + (hc_c − h)·exp(−agl/dx) (h — настоящая земля под точкой,
## agl = y − h): у земли — та же высота над землёй сетки, что у пилота над настоящей; выше
## подсеточные неровности рельефа гаснут на масштабе клетки, и выборка идёт по абсолютной высоте.

## Шероховатость для лог-профиля у земли, м (как в решателе).
var z0: float = 0.1
var dx: float = 100.0
var dz: float = 50.0
## Западный и южный края сетки (x, y = −Z мира), низ сетки (над морем), м.
var x0: float = 0.0
var y0: float = 0.0
var z_bot: float = 0.0
var nx: int = 0
var ny: int = 0
var nz: int = 0
## Ширина полосы края, клеток: у боковых граней и верха поле плавно уступает аналитике.
var edge_cells: float = 5.0
## Метаданные источника (json поля: cond, source, probes …).
var meta: Dictionary = {}
## Применённые ограничители (max_speed, max_w), м/с.
var limits := Vector2(INF, INF)

## u, v, w_mech подряд на клетку: ((k·ny + j)·nx + i)·3 + канал.
var _vel := PackedFloat32Array()
var _wconv := PackedFloat32Array()
var _theta := PackedFloat32Array()
## Высота рельефа сетки по столбцам (j·nx + i), м.
var _hc := PackedFloat32Array()
## Первая воздушная клетка столбца (nz — столбец целиком в земле).
var _k1 := PackedInt32Array()
## 1 / ln(a1 / z0), a1 — высота центра первой воздушной клетки над hc столбца.
var _inv_log1 := PackedFloat32Array()
var _nxy: int = 0
var _inv_dx: float = 0.01
var _inv_dz: float = 0.02
var _z_top: float = 0.0


## Поле из массивов в центрах клеток (API решателя AM-03 и библиотеки полей AM-06б).
## m: {dx, dz, x0, y0, z_bot, nx, ny, nz, z0?}; массивы — nz·ny·nx (раскладка выше), hc — ny·nx.
## Нечисловые значения (NaN, ∞) → 0; ограничители (clamp_values) — сразу, за тот же проход.
## Стоит O(n) в GDScript (~0,2–0,4 с на 64 × 64 × 62) — строить в рабочем потоке (класс не трогает
## сцену), в главном — только AirFieldSet.set_field. null — размеры не сходятся.
static func from_arrays(
	m: Dictionary,
	u: PackedFloat32Array,
	v: PackedFloat32Array,
	w_mech: PackedFloat32Array,
	w_conv: PackedFloat32Array,
	theta: PackedFloat32Array,
	hc: PackedFloat32Array,
	max_speed: float = 40.0,
	max_w: float = 10.0
) -> WindField:
	var f := WindField.new()
	f.meta = m
	f.dx = float(m.dx)
	f.dz = float(m.dz)
	f.x0 = float(m.x0)
	f.y0 = float(m.y0)
	f.z_bot = float(m.z_bot)
	f.nx = int(m.nx)
	f.ny = int(m.ny)
	f.nz = int(m.nz)
	f.z0 = float(m.get("z0", 0.1))
	var n := f.nx * f.ny * f.nz
	if f.nx < 2 or f.ny < 2 or f.nz < 2 or hc.size() != f.nx * f.ny:
		push_error("WindField: неверные размеры сетки")
		return null
	for a: PackedFloat32Array in [u, v, w_mech, w_conv, theta]:
		if a.size() != n:
			push_error("WindField: размер массива %d ≠ %d" % [a.size(), n])
			return null
	var vel := PackedFloat32Array()
	vel.resize(n * 3)
	var wc := w_conv.duplicate()
	var th := theta.duplicate()
	for c in n:
		var a := u[c]
		var b := v[c]
		var w := w_mech[c]
		var q := wc[c]
		if not (
			is_finite(a) and is_finite(b) and is_finite(w) and is_finite(q) and is_finite(th[c])
		):
			a = _finite(a)
			b = _finite(b)
			w = _finite(w)
			wc[c] = _finite(q)
			th[c] = _finite(th[c])
		var i := c * 3
		vel[i] = a
		vel[i + 1] = b
		vel[i + 2] = w
	f._vel = vel
	f._wconv = wc
	f._theta = th
	f._hc = hc.duplicate()
	f._build_columns()
	f.clamp_values(max_speed, max_w)
	return f


## Поле из массивов MAC-решателя с ореолом (как в эталонах AM-01, fixtures.py): (NZ, NY, NX) =
## (nz + 2, ny + 2, nx + 2); u[k, j, i] — западная грань клетки i (между i − 1 и i), v — южная,
## w — нижняя; cell — 0 земля, иначе воздух. Скорости переносятся в центры (среднее двух граней),
## как `centers()` решателя. w_mech_faces — w решения без нагрева на той же сетке.
static func from_mac(
	m: Dictionary,
	u: PackedFloat32Array,
	v: PackedFloat32Array,
	w: PackedFloat32Array,
	w_mech_faces: PackedFloat32Array,
	theta: PackedFloat32Array,
	cell: PackedFloat32Array,
	hc: PackedFloat32Array
) -> WindField:
	var mx := int(m.nx)
	var my := int(m.ny)
	var mz := int(m.nz)
	var hx := mx + 2
	var hy := my + 2
	var hn := hx * hy * (mz + 2)
	for a: PackedFloat32Array in [u, v, w, w_mech_faces, theta, cell]:
		if a.size() != hn:
			push_error("WindField.from_mac: размер массива %d ≠ %d" % [a.size(), hn])
			return null
	var n := mx * my * mz
	var cu := PackedFloat32Array()
	var cv := PackedFloat32Array()
	var cw := PackedFloat32Array()
	var cc := PackedFloat32Array()
	var ct := PackedFloat32Array()
	for a: PackedFloat32Array in [cu, cv, cw, cc, ct]:
		a.resize(n)
	var sy := hx
	var sz := hx * hy
	for k in mz:
		for j in my:
			for i in mx:
				var h := ((k + 1) * hy + j + 1) * hx + i + 1
				var c := (k * my + j) * mx + i
				if cell[h] == 0.0:
					continue
				cu[c] = 0.5 * (u[h] + u[h + 1])
				cv[c] = 0.5 * (v[h] + v[h + sy])
				var wm := 0.5 * (w_mech_faces[h] + w_mech_faces[h + sz])
				cw[c] = wm
				cc[c] = 0.5 * (w[h] + w[h + sz]) - wm
				ct[c] = theta[h]
	return from_arrays(m, cu, cv, cw, cc, ct, hc)


## Прочитать поле из файла: <путь>.json (метаданные, arrays: {имя: [смещение, длина]} в числах
## float32) + <путь>.bin (float32 LE). Путь — с .json или без расширения. null — ошибка.
static func load_file(path: String) -> WindField:
	var base := path.trim_suffix(".json").trim_suffix(".bin")
	var js: Variant = JSON.parse_string(FileAccess.get_file_as_string(base + ".json"))
	if not js is Dictionary or not (js as Dictionary).has("arrays"):
		push_error("WindField: нет или не читается %s.json" % base)
		return null
	var m: Dictionary = js
	var raw := FileAccess.get_file_as_bytes(base + ".bin")
	if raw.is_empty():
		push_error("WindField: нет %s.bin" % base)
		return null
	var all := raw.to_float32_array()
	var arr := {}
	for name in ["u", "v", "w_mech", "w_conv", "theta", "hc"]:
		if not (m.arrays as Dictionary).has(name):
			push_error("WindField: в %s нет массива %s" % [base, name])
			return null
		var ol: Array = m.arrays[name]
		arr[name] = all.slice(int(ol[0]), int(ol[0]) + int(ol[1]))
	var f := from_arrays(m, arr.u, arr.v, arr.w_mech, arr.w_conv, arr.theta, arr.hc)
	if f != null:
		f.meta["path"] = base
	return f


static func _finite(x: float) -> float:
	return x if is_finite(x) else 0.0


func _build_columns() -> void:
	_nxy = nx * ny
	_inv_dx = 1.0 / dx
	_inv_dz = 1.0 / dz
	_z_top = z_bot + nz * dz
	_k1.resize(_nxy)
	_inv_log1.resize(_nxy)
	for c in _nxy:
		# под землёй — центр ниже hc: первая воздушная — наименьшая k с z_bot + (k + ½)dz ≥ hc
		var k1 := clampi(ceili((_hc[c] - z_bot) * _inv_dz - 0.5), 0, nz)
		_k1[c] = k1
		var a1 := maxf(z_bot + (k1 + 0.5) * dz - _hc[c], 2.0 * z0)
		_inv_log1[c] = 1.0 / log(a1 / z0)


## Ограничители (на всякий случай — решение без срыва на обрыве может дать лишнее): модуль
## горизонтали ≤ max_speed, |w_mech|, |w_conv| ≤ max_w, м/с. Повтор с теми же — без прохода.
func clamp_values(max_speed: float, max_w: float) -> void:
	var lim := Vector2(max_speed, max_w)
	if limits == lim:
		return
	limits = lim
	var s2 := max_speed * max_speed
	for c in _nxy * nz:
		var i := c * 3
		var a := _vel[i]
		var b := _vel[i + 1]
		var ss := a * a + b * b
		if ss > s2:
			var k := max_speed / sqrt(ss)
			_vel[i] = a * k
			_vel[i + 1] = b * k
		var w := _vel[i + 2]
		if absf(w) > max_w:
			_vel[i + 2] = clampf(w, -max_w, max_w)
		var q := _wconv[c]
		if absf(q) > max_w:
			_wconv[c] = clampf(q, -max_w, max_w)


## Точка внутри поля (по горизонтали и между низом и верхом сетки).
func contains(pos: Vector3) -> bool:
	var gx := (pos.x - x0) * _inv_dx
	var gy := (-pos.z - y0) * _inv_dx
	return gx >= 0.0 and gx <= nx and gy >= 0.0 and gy <= ny and pos.y >= z_bot and pos.y <= _z_top


## Вес поля 0..1: 1 внутри, в полосе края (edge_cells клеток у боковых граней, столько же клеток
## dz под верхом) плавно (smoothstep) → 0 на границе, 0 снаружи.
func edge_weight(pos: Vector3) -> float:
	var gx := (pos.x - x0) * _inv_dx
	var gy := (-pos.z - y0) * _inv_dx
	var d := minf(minf(gx, nx - gx), minf(gy, ny - gy))
	d = minf(d, (_z_top - pos.y) * _inv_dz)
	if d <= 0.0:
		return 0.0
	if d >= edge_cells:
		return 1.0
	return smoothstep(0.0, edge_cells, d)


## Скорость воздуха (u, w_mech, v → мир: x — восток, y — вверх, z — юг), м/с. ground_h — высота
## настоящей земли под точкой (NAN — рельеф сетки). Вне поля — значения ближайшего края.
func sample(pos: Vector3, ground_h: float = NAN) -> Vector3:
	var gx := clampf((pos.x - x0) * _inv_dx - 0.5, 0.0, nx - 1.0)
	var gy := clampf((-pos.z - y0) * _inv_dx - 0.5, 0.0, ny - 1.0)
	var i0 := mini(int(gx), nx - 2)
	var j0 := mini(int(gy), ny - 2)
	var fx := gx - i0
	var fy := gy - j0
	var c := j0 * nx + i0
	var sh := _shift(pos, ground_h, c, fx, fy)
	var a := _col_vel(c, pos.y, sh)
	var b := _col_vel(c + 1, pos.y, sh)
	var r0 := a + (b - a) * fx
	a = _col_vel(c + nx, pos.y, sh)
	b = _col_vel(c + nx + 1, pos.y, sh)
	var r := r0 + (a + (b - a) * fx - r0) * fy
	return Vector3(r.x, r.z, -r.y)


## θ′ (К) в точке — как sample, у земли — значение первой воздушной клетки (без профиля).
func sample_theta(pos: Vector3, ground_h: float = NAN) -> float:
	return _sample_scalar(_theta, pos, ground_h, false)


## Конвективная вертикаль w_conv (м/с) — пилоту напрямую не отдаётся (только пузыри, AM-07).
func sample_w_conv(pos: Vector3, ground_h: float = NAN) -> float:
	return _sample_scalar(_wconv, pos, ground_h, true)


## Высота рельефа сетки (билинейно по центрам столбцов), м. x, z — мир.
func ground_height(x: float, z: float) -> float:
	var gx := clampf((x - x0) * _inv_dx - 0.5, 0.0, nx - 1.0)
	var gy := clampf((-z - y0) * _inv_dx - 0.5, 0.0, ny - 1.0)
	var i0 := mini(int(gx), nx - 2)
	var j0 := mini(int(gy), ny - 2)
	var fx := gx - i0
	var fy := gy - j0
	var c := j0 * nx + i0
	var h0 := lerpf(_hc[c], _hc[c + 1], fx)
	return lerpf(h0, lerpf(_hc[c + nx], _hc[c + nx + 1], fx), fy)


## Центр поля (x, z мира) и размер по x, м.
func center_xz() -> Vector2:
	return Vector2(x0 + 0.5 * nx * dx, -(y0 + 0.5 * ny * dx))


func size_x() -> float:
	return nx * dx


## Сдвиг высоты выборки по столбцам: z_c = y + (hc_c − h)·e, e = exp(−agl/dx). Возвращает
## Vector2(e, h): столбец c читается на высоте y + (hc_c − h)·e.
func _shift(pos: Vector3, ground_h: float, c: int, fx: float, fy: float) -> Vector2:
	var h := ground_h
	if is_nan(h):
		var h0 := lerpf(_hc[c], _hc[c + 1], fx)
		h = lerpf(h0, lerpf(_hc[c + nx], _hc[c + nx + 1], fx), fy)
	return Vector2(exp(-maxf(pos.y - h, 0.0) * _inv_dx), h)


## (u, v, w_mech) столбца c на высоте y (со сдвигом sh от _shift).
func _col_vel(c: int, y: float, sh: Vector2) -> Vector3:
	var k1 := _k1[c]
	if k1 >= nz:
		return Vector3.ZERO
	var hcol := _hc[c]
	var z := y + (hcol - sh.y) * sh.x
	var kf := (z - z_bot) * _inv_dz - 0.5
	if kf >= k1:
		var k := int(kf)
		var t := kf - k
		if k >= nz - 1:
			k = nz - 2
			t = 1.0
		var i := ((k * _nxy) + c) * 3
		var i2 := i + _nxy * 3
		var p := Vector3(_vel[i], _vel[i + 1], _vel[i + 2])
		return p + (Vector3(_vel[i2], _vel[i2 + 1], _vel[i2 + 2]) - p) * t
	# ниже центра первой воздушной клетки: лог-профиль к нулю на z0 над землёй сетки
	var agl := z - hcol
	if agl <= z0:
		return Vector3.ZERO
	var i1 := ((k1 * _nxy) + c) * 3
	var f := minf(log(agl / z0) * _inv_log1[c], 1.0)
	return Vector3(_vel[i1], _vel[i1 + 1], _vel[i1 + 2]) * f


func _sample_scalar(
	arr: PackedFloat32Array, pos: Vector3, ground_h: float, log_prof: bool
) -> float:
	var gx := clampf((pos.x - x0) * _inv_dx - 0.5, 0.0, nx - 1.0)
	var gy := clampf((-pos.z - y0) * _inv_dx - 0.5, 0.0, ny - 1.0)
	var i0 := mini(int(gx), nx - 2)
	var j0 := mini(int(gy), ny - 2)
	var fx := gx - i0
	var fy := gy - j0
	var c := j0 * nx + i0
	var sh := _shift(pos, ground_h, c, fx, fy)
	var r0 := lerpf(
		_col_scalar(arr, c, pos.y, sh, log_prof), _col_scalar(arr, c + 1, pos.y, sh, log_prof), fx
	)
	var r1 := lerpf(
		_col_scalar(arr, c + nx, pos.y, sh, log_prof),
		_col_scalar(arr, c + nx + 1, pos.y, sh, log_prof),
		fx
	)
	return lerpf(r0, r1, fy)


func _col_scalar(arr: PackedFloat32Array, c: int, y: float, sh: Vector2, log_prof: bool) -> float:
	var k1 := _k1[c]
	if k1 >= nz:
		return 0.0
	var hcol := _hc[c]
	var z := y + (hcol - sh.y) * sh.x
	var kf := (z - z_bot) * _inv_dz - 0.5
	if kf >= k1:
		var k := int(kf)
		var t := kf - k
		if k >= nz - 1:
			k = nz - 2
			t = 1.0
		var i := k * _nxy + c
		return lerpf(arr[i], arr[i + _nxy], t)
	var v1 := arr[k1 * _nxy + c]
	if not log_prof:
		return v1
	var agl := z - hcol
	if agl <= z0:
		return 0.0
	return v1 * minf(log(agl / z0) * _inv_log1[c], 1.0)
